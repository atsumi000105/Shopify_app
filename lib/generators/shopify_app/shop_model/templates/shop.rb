class Shop < ActiveRecord::Base
  include ShopifyApp::ShopSessionStorage

  def api_version
    ShopifyApp.configuration.api_version
  end
end
