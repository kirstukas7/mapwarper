class ApplicationController < ActionController::Base
  # Prevent CSRF attacks by raising an exception.
  # For APIs, you may want to use :null_session instead.
  protect_from_forgery with: :exception

  before_filter :configure_permitted_parameters, if: :devise_controller?

  before_filter :set_locale

  before_action :require_hcaptcha
    
  def check_super_user_role
    check_role('super user')
  end

  def check_administrator_role
    check_role("administrator")
  end
  
  def check_editor_role
    check_role("editor")
  end

  def check_developer_role
    check_role("developer")
  end


  protected

  def configure_permitted_parameters
    devise_parameter_sanitizer.permit(:sign_up) do |u|
      u.permit :login, :description, :email, :password, :password_confirmation
    end
    devise_parameter_sanitizer.permit(:account_update) do |u|
      u.permit :login, :description, :email, :password, :password_confirmation, :current_password
    end
  end

  def default_url_options(options={})
    I18n.locale == I18n.default_locale ? {} : { :locale => I18n.locale }
  end

  def set_locale
    I18n.locale = params[:locale] || I18n.default_locale
  rescue I18n::InvalidLocale
    I18n.locale = I18n.default_locale
  end

  # Lets browsers and CDNs such as Cloudflare cache map imagery (tiles, WMS GetMap).
  # Must run before caches_action, which replays cached bodies without the headers
  # set inside the action. No session cookie is sent, so the response is cacheable.
  def set_public_tile_cache_headers
    wms_request = (params[:request] || params[:REQUEST]).to_s
    return if wms_request.casecmp("GetCapabilities").zero?

    request.session_options[:skip] = true
    expires_in ENV.fetch('TILE_CACHE_MAX_AGE', 1.day).to_i, :public => true
  end

  # Don't let CDNs keep errors (e.g. a tile requested before the map is warped,
  # or a Mapserver XML exception) around after the map changes.
  def expires_now_unless_image
    expires_now unless response.status == 200 && response.content_type.to_s.start_with?("image/")
  end
  
  def check_role(role)
    unless user_signed_in? && @current_user.has_role?(role)
      permission_denied
    end
  end

  def permission_denied
    flash[:error] = t('application.permission_denied')
    redirect_to root_path
  end


  def require_hcaptcha
    return unless ENV["HCAPTCHA_SITE_KEY"]
    return if user_signed_in?
    return if captcha_verified?
    return if captcha_controller?
    return if action_name == 'show' && request.format.kml?
  
    redirect_to hcaptcha_verify_path(return_to: request.fullpath)
  end

  def captcha_verified?
    session[:hcaptcha_verified] == true
  end

  def captcha_controller?
    controller_name == "captcha"
  end


end
