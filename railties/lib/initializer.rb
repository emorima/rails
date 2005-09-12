require 'logger'

RAILS_ENV = ENV['RAILS_ENV'] || 'development'

module Rails
  # The Initializer is responsible for processing the Rails configuration, such as setting the $LOAD_PATH, requiring the
  # right frameworks, initializing logging, and more. It can be run either as a single command that'll just use the 
  # default configuration, like this:
  #
  #   Rails::Initializer.run
  #
  # But normally it's more interesting to pass in a custom configuration through the block running:
  #
  #   Rails::Initializer.run do |config|
  #     config.frameworks -= [ :action_web_service ]
  #   end
  #
  # This will use the default configuration options from Rails::Configuration, but allow for overwriting on select areas.
  class Initializer
    attr_reader :configuration
    
    def self.run(command = :process, configuration = Configuration.new)
      yield configuration if block_given?
      new(configuration).send(command)
    end
    
    def initialize(configuration)
      @configuration = configuration
    end
    
    def process
      set_load_path

      require_frameworks
      require_environment

      initialize_database
      initialize_logger
      initialize_framework_logging
      initialize_framework_views
      initialize_routing
      initialize_session_settings
      initialize_session_store
      initialize_fragment_store
    end
    
    def set_load_path
      configuration.load_paths.reverse.each { |dir| $LOAD_PATH.unshift(dir) if File.directory?(dir) }
      $LOAD_PATH.uniq!
    end
    
    def require_frameworks
      configuration.frameworks.each { |framework| require(framework.to_s) }
    end
    
    def require_environment
      require_dependency(configuration.environment_file)
    end
    
    def initialize_database
      return unless configuration.frameworks.include?(:active_record)
      ActiveRecord::Base.configurations = configuration.database_configuration
      ActiveRecord::Base.establish_connection
    end
    
    def initialize_logger
      # if the environment has explicitly defined a logger, use it
      return if defined?(RAILS_DEFAULT_LOGGER)

      begin
        logger = Logger.new(configuration.log_path)
        logger.level = Logger.const_get(configuration.log_level.to_s.upcase)
      rescue StandardError
        logger = Logger.new(STDERR)
        logger.level = Logger::WARN
        logger.warn(
          "Rails Error: Unable to access log file. Please ensure that #{configuration.log_path} exists and is chmod 0666. " +
          "The log level has been raised to WARN and the output directed to STDERR until the problem is fixed."
        )
      end
      
      silence_warnings { Object.const_set "RAILS_DEFAULT_LOGGER", logger }
    end
    
    def initialize_framework_logging
      # TODO: Only do logging for frameworks loaded
      [ActiveRecord, ActionController, ActionMailer].each { |mod| mod::Base.logger ||= RAILS_DEFAULT_LOGGER }        
    end
    
    def initialize_framework_views
      # TODO: Only do view setting for frameworks loaded
      [ActionController, ActionMailer].each { |mod| mod::Base.template_root ||= configuration.view_path }        
    end

    def initialize_routing
      return unless configuration.frameworks.include?(:action_controller)
      ActionController::Routing::Routes.reload
      Object.const_set "Controllers", Dependencies::LoadingModule.root(*configuration.controller_paths)
    end
    
    def initialize_session_settings
      return unless configuration.frameworks.include?(:action_controller)
      ActionController::CgiRequest::DEFAULT_SESSION_OPTIONS.merge!(configuration.session_options)
    end

    def initialize_session_store
      return if !configuration.frameworks.include?(:action_controller) || configuration.session_store.nil?
      
      if configuration.session_store.is_a?(Symbol)
        ActionController::CgiRequest::DEFAULT_SESSION_OPTIONS[:database_manager] =
          CGI::Session.const_get(configuration.session_store.to_s.camelize)
      else
        ActionController::CgiRequest::DEFAULT_SESSION_OPTIONS[:database_manager] = configuration.session_store
      end
    end
    
    def initialize_fragment_store
      return if !configuration.frameworks.include?(:action_controller) || configuration.fragment_store.nil?

      configuration.fragment_store = [ configuration.fragment_store ].flatten
      store = ActionController::Caching::Fragments.const_get(configuration.fragment_store.first.to_s.camelize)

      if parameters = configuration.fragment_store[1..-1]
        ActionController::Base.fragment_cache_store = store.new(*parameters)
      else
        ActionController::Base.fragment_cache_store = store.new
      end
    end
  end
  
  # The Configuration class holds all the parameters for the Initializer and ships with defaults that suites most
  # Rails applications. But it's possible to overwrite everything. Usually, you'll create an Configuration file implicitly
  # through the block running on the Initializer, but it's also possible to create the Configuration instance in advance and
  # pass it in like this:
  #
  #   config = Rails::Configuration.new
  #   Rails::Initializer.run(:process, config)
  class Configuration
    attr_accessor :frameworks, :load_paths, :log_level, :log_path, :database_configuration_file, :view_path, :controller_paths
    attr_accessor :session_options, :session_store, :fragment_store
    
    def initialize
      self.frameworks       = default_frameworks
      self.load_paths       = default_load_paths
      self.log_path         = default_log_path
      self.log_level        = default_log_level
      self.view_path        = default_view_path
      self.controller_paths = default_controller_paths
      self.session_options  = default_session_options
      self.database_configuration_file  = default_database_configuration_file
    end
    
    def database_configuration
      YAML::load(ERB.new((IO.read(database_configuration_file))).result)
    end
    
    def environment_file
      "environments/#{environment}"
    end
    
    def environment
      ::RAILS_ENV
    end
    
    private
      def default_frameworks
        [ :active_support, :active_record, :action_controller, :action_mailer, :action_web_service ]
      end
    
      def default_load_paths
        paths = ["#{RAILS_ROOT}/test/mocks/#{environment}"]

        # Then model subdirectories.
        # TODO: Don't include .rb models as load paths
        paths.concat(Dir["#{RAILS_ROOT}/app/models/[_a-z]*"])
        paths.concat(Dir["#{RAILS_ROOT}/components/[_a-z]*"])

        # Followed by the standard includes.
        # TODO: Don't include dirs for frameworks that are not used
        paths.concat %w(
          app 
          app/models 
          app/controllers 
          app/helpers 
          app/apis 
          components 
          config 
          lib 
          vendor 
          vendor/rails/railties
          vendor/rails/railties/lib
          vendor/rails/actionpack/lib
          vendor/rails/activesupport/lib
          vendor/rails/activerecord/lib
          vendor/rails/actionmailer/lib
          vendor/rails/actionwebservice/lib
        ).map { |dir| "#{RAILS_ROOT}/#{dir}" }.select { |dir| File.directory?(dir) }
      end

      def default_log_path
        File.join(RAILS_ROOT, 'log', "#{environment}.log")
      end
      
      def default_log_level
        environment == 'production' ? :info : :debug
      end
      
      def default_database_configuration_file
        File.join(RAILS_ROOT, 'config', 'database.yml')
      end
      
      def default_view_path
        File.join(RAILS_ROOT, 'app', 'views')
      end
      
      def default_controller_paths
        [ File.join(RAILS_ROOT, 'app', 'controllers'), File.join(RAILS_ROOT, 'components') ]
      end
      
      def default_session_options
        {}
      end
  end
end
