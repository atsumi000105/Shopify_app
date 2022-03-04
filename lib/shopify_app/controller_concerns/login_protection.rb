# frozen_string_literal: true

require 'browser_sniffer'

module ShopifyApp
  module LoginProtection
    extend ActiveSupport::Concern
    include ShopifyApp::Itp

    class ShopifyDomainNotFound < StandardError; end

    class ShopifyHostNotFound < StandardError; end

    included do
      after_action :set_test_cookie
      rescue_from ShopifyAPI::Errors::HttpResponseError, with: :handle_http_error
    end

    ACCESS_TOKEN_REQUIRED_HEADER = 'X-Shopify-API-Request-Failure-Unauthorized'

    def activate_shopify_session
      if current_shopify_session.blank?
        signal_access_token_required
        return redirect_to_login
      end

      unless current_shopify_session.scope.to_a.empty? ||
        current_shopify_session.scope.covers?(ShopifyAPI::Context.scope)

        clear_shopify_session
        return redirect_to_login
      end

      begin
        ShopifyAPI::Context.activate_session(current_shopify_session)
        yield
      ensure
        ShopifyAPI::Context.deactivate_session
      end
    end

    def current_shopify_session
      @current_shopify_session ||= begin
        ShopifyAPI::Utils::SessionUtils.load_current_session(
          auth_header: request.headers['HTTP_AUTHORIZATION'],
          cookies: cookies.to_h,
          is_online: user_session_expected?
        )
      rescue ShopifyAPI::Errors::CookieNotFoundError => e
        nil
      rescue ShopifyAPI::Errors::InvalidJwtTokenError => e
        nil
      end
    end

    def login_again_if_different_user_or_shop
      if current_shopify_session&.session&.present? && params[:session].present? # session data was sent/stored correctly
        clear_session = current_shopify_session.session != params[:session] # current session is different from stored session
      end

      if current_shopify_session &&
        params[:shop] && params[:shop].is_a?(String) &&
        (current_shopify_session.shop != params[:shop])
        clear_session = true
      end

      if clear_session
        clear_shopify_session
        redirect_to_login
      end
    end

    def signal_access_token_required
      response.set_header(ACCESS_TOKEN_REQUIRED_HEADER, "true")
    end

    def jwt_expire_at
      expire_at = request.env['jwt.expire_at']
      return unless expire_at
      expire_at - 5.seconds # 5s gap to start fetching new token in advance
    end

    protected

    def jwt_shopify_domain
      request.env['jwt.shopify_domain']
    end

    def jwt_shopify_user_id
      request.env['jwt.shopify_user_id']
    end

    def host
      return params[:host] if params[:host].present?

      raise ShopifyHostNotFound
    end

    def redirect_to_login
      if request.xhr?
        head(:unauthorized)
      else
        if request.get?
          path = request.path
          query = sanitized_params.to_query
        else
          referer = URI(request.referer || "/")
          path = referer.path
          query = "#{referer.query}&#{sanitized_params.to_query}"
        end
        session[:return_to] = query.blank? ? path.to_s : "#{path}?#{query}"
        redirect_to(login_url_with_optional_shop)
      end
    end

    def close_session
      clear_shopify_session
      redirect_to(login_url_with_optional_shop)
    end

    def handle_http_error(error)
      if error.code == 401
        close_session
      else
        raise error
      end
    end

    def clear_shopify_session
      cookies[ShopifyAPI::Auth::Oauth::SessionCookie::SESSION_COOKIE_NAME] = nil
    end

    def login_url_with_optional_shop(top_level: false)
      url = ShopifyApp.configuration.login_url

      query_params = login_url_params(top_level: top_level)

      url = "#{url}?#{query_params.to_query}" if query_params.present?
      url
    end

    def login_url_params(top_level:)
      query_params = {}
      query_params[:shop] = sanitized_params[:shop] if params[:shop].present?

      return_to = RedirectSafely.make_safe(session[:return_to] || params[:return_to], nil)

      if return_to.present? && return_to_param_required?
        query_params[:return_to] = return_to
      end

      has_referer_shop_name = referer_sanitized_shop_name.present?

      if has_referer_shop_name
        query_params[:shop] ||= referer_sanitized_shop_name
      end

      query_params[:top_level] = true if top_level
      query_params
    end

    def return_to_param_required?
      native_params = %i[shop hmac timestamp locale protocol return_to]
      request.path != '/' || sanitized_params.except(*native_params).any?
    end

    def fullpage_redirect_to(url)
      if ShopifyApp.configuration.embedded_app?
        render('shopify_app/shared/redirect', layout: false,
               locals: { url: url, current_shopify_domain: current_shopify_domain })
      else
        redirect_to(url)
      end
    end

    def current_shopify_domain
      shopify_domain = sanitized_shop_name || current_shopify_session&.shop

      return shopify_domain if shopify_domain.present?

      raise ShopifyDomainNotFound
    end

    def sanitized_shop_name
      @sanitized_shop_name ||= sanitize_shop_param(params)
    end

    def referer_sanitized_shop_name
      return unless request.referer.present?

      @referer_sanitized_shop_name ||= begin
        referer_uri = URI(request.referer)
        query_params = Rack::Utils.parse_query(referer_uri.query)

        sanitize_shop_param(query_params.with_indifferent_access)
      end
    end

    def sanitize_shop_param(params)
      return unless params[:shop].present?
      ShopifyApp::Utils.sanitize_shop_domain(params[:shop])
    end

    def sanitized_params
      request.query_parameters.clone.tap do |query_params|
        if params[:shop].is_a?(String)
          query_params[:shop] = sanitize_shop_param(params)
        end
      end
    end

    def return_address
      return_address_with_params(shop: current_shopify_domain, host: host)
    rescue ShopifyDomainNotFound, ShopifyHostNotFound
      base_return_address
    end

    def base_return_address
      session.delete(:return_to) || ShopifyApp.configuration.root_url
    end

    def return_address_with_params(params)
      uri = URI(base_return_address)
      uri.query = CGI.parse(uri.query.to_s)
        .symbolize_keys
        .transform_values { |v| v.one? ? v.first : v }
        .merge(params)
        .to_query
      uri.to_s
    end

    private

    def user_session_expected?
      !ShopifyApp.configuration.user_session_repository.blank? && ShopifyApp::SessionRepository.user_storage.present?
    end
  end
end
