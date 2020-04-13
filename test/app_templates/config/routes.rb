# frozen_string_literal: true
Rails.application.routes.draw do
  mount ShopifyApp::Engine, at: '/'
  root to: "application#show"
end
