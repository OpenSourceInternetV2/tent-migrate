require 'sinatra'
require 'sprockets'
require 'coffee_script'
require 'sass'
require 'yajl'
require 'omniauth-tent'
require 'tent-migrate/data'
require 'tent-migrate/worker'

module TentMigrate
  class App < Sinatra::Base
    module SprocketsHelpers
      def asset_path(source, options = {})
        "./#{(p = environment.find_asset(source); p ? p.digest_path : '')}"
      end
    end

    module SprocketsEnvironment
      def self.assets
        return @assets if defined?(@assets)
        puts 'SprocketsEnvironment loaded'
        @assets = Sprockets::Environment.new do |env|
          env.logger = Logger.new(STDOUT)
          env.context_class.class_eval do
            include SprocketsHelpers
          end
        end

        paths = %w{ javascripts stylesheets images }
        paths.each do |path|
          @assets.append_path(File.expand_path(File.join(File.dirname(__FILE__), "assets", path)))
        end
        @assets
      end
    end

    configure do
      set :assets, SprocketsEnvironment.assets
      set :cdn_url, false
      set :asset_manifest, false
      set :method_override, true
      set :views, File.expand_path(File.join(File.dirname(__FILE__), 'views'))
    end

    configure :production do
      set :asset_manifest, Yajl::Parser.parse(File.read(ENV['ASSET_MANIFEST'])) if ENV['ASSET_MANIFEST']
      set :cdn_url, ENV['CDN_URL']
    end

    helpers do
      def asset_path(path)
        path = asset_manifest_path(path) || (p = settings.assets.find_asset(path); p ? p.digest_path : path)
        if settings.cdn_url?
          "#{settings.cdn_url}/assets/#{path}"
        else
          full_path("/assets/#{path}")
        end
      end

      def asset_manifest_path(asset)
        if settings.asset_manifest?
          settings.asset_manifest['files'].detect { |k,v| v['logical_path'] == asset }[0]
        end
      end

      def path_prefix
        env['SCRIPT_NAME']
      end

      def full_path(path)
        "#{path_prefix}/#{path}".gsub(%r{//}, '/')
      end

      def auth_container_class(auth_type)
        case auth_type
        when :export
          "disabled" if session['job_key']
        when :import
          "disabled" unless session['job_key']
        end
      end

      def method_override(method)
        "<input type='hidden' name='_method' value='#{method}' />"
      end
    end

    if ENV['RACK_ENV'] != 'production' || !ENV['CDN_URL']
      get '/assets/*' do
        asset = params[:splat].first
        path = "./public/assets/#{asset}"
        if File.exists?(path)
          content_type = case asset.split('.').last
                         when 'css'
                           'text/css'
                         when 'js'
                           'application/javascript'
                         end
          headers = { 'Content-Type' => content_type } if content_type
          [200, headers, [File.read(path)]]
        else
          new_env = env.clone
          new_env["PATH_INFO"].gsub!("/assets", "")
          settings.assets.call(new_env)
        end
      end
    end

    use OmniAuth::Strategies::Tent, {
      :request_path => '/export/auth/tent',
      :callback_path => '/export/auth/tent/callback',
      :app => {
        :name => 'Migrate',
        :description => 'Move your data',
        :icon => '',
        :url => ENV['HOST_DOMAIN'],
        :scopes => {
          'read_posts'        => 'Export posts',
          'write_posts'       => 'Send notification post when migration complete',
          'read_profile'      => 'Access your basic information',
          'read_followers'    => 'Export followers',
          'read_followings'   => 'Export followings',
          'read_groups'       => 'Export groups',
          'read_permissions'  => 'Export permissions for each resource',
          'read_apps'         => 'Export apps',
          'read_secrets'      => 'Maintain mac keys for exported resources',
        }
      },
      :profile_info_types => %w( all ),
      :post_types => %w( all ),
      :notification_url => ENV['NOTIFICATION_URL'].to_s,
      :get_app => lambda { |entity|
        Data.get_export_app(entity)
      },
    }

    use OmniAuth::Strategies::Tent, {
      :request_path => '/import/auth/tent',
      :callback_path => '/import/auth/tent/callback',
      :app => {
        :name => 'Migrate',
        :description => 'Move your data',
        :icon => '',
        :url => ENV['HOST_DOMAIN'],
        :scopes => {
          'read_posts'        => '',
          'import_posts'      => 'Import posts',
          'write_posts'       => '',
          'read_profile'      => 'Access your basic information',
          'write_profile'     => 'Import profile',
          'read_followers'    => '',
          'write_followers'   => 'Import followers',
          'read_followings'   => '',
          'write_followings'  => 'Import followings',
          'read_groups'       => '',
          'write_groups'      => 'Import groups',
          'read_permissions'  => '',
          'write_permissions' => 'Import permissions for resources',
          'read_apps'         => '',
          'write_apps'        => 'Import apps and app authorizations',
          'read_secrets'      => '',
          'write_secrets'     => 'Import mac keys for followings, followers, and apps',
        }
      },
      :profile_info_types => %w( all ),
      :post_types => %w( all ),
      :notification_url => ENV['NOTIFICATION_URL'].to_s,
      :get_app => lambda { |entity|
        Data.get_import_app(entity)
      },
    }

    get '/' do
      if @job_key = session['job_key']
        @export_entity = (Data.get_job_export_app(@job_key) || {})['entity']
        @import_entity = (Data.get_job_export_app(@job_key) || {})['entity']
      end

      erb :index
    end

    get '/export/auth/tent/callback' do
      session['job_key'] = job_key = SecureRandom.hex(4)
      app_key = Data.set_export_app_from_auth_hash(env['omniauth.auth'])
      Data.set_job_export_app(job_key, app_key)

      redirect '/'
    end

    get '/import/auth/tent/callback' do
      job_key = session.delete('job_key')
      redirect '/' and return unless job_key

      app_key = Data.set_import_app_from_auth_hash(env['omniauth.auth'])
      Data.set_job_import_app(job_key, app_key)
      Data.set_job_stat(job_key, 'started_at', Time.now.to_i)

      Worker::MIGRATE_QUEUE << job_key

      redirect "/jobs/#{job_key}"
    end

    get '/auth/failure' do
      redirect '/?auth_error=true'
    end

    get '/jobs/:job_key' do
      job_key = params[:job_key]
      stats = Data.get_job_stats(job_key)
      redirect '/' unless stats

      @stats = Hashie::Mash.new(stats)
      @stats.exported_post_ids = Data.job_stat_set_get(job_key, 'exported_post_ids')
      @stats.imported_post_ids = Data.job_stat_set_get(job_key, 'imported_post_ids')
      @stats.failed_post_ids = Data.job_stat_set_diff(job_key, 'exported_post_ids', 'imported_post_ids')
      erb :stats
    end

    delete '/jobs/:job_key' do
      Data.delete_job(params[:job_key])
      session.delete('job_key')
      redirect '/'
    end

    post '/webhooks' do
      status 200
    end
  end
end
