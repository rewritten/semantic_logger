# Base logger
#
#   Abstract base class for loggers
#
#   Implements common behavior such as log level, default text formatter etc
#
module SemanticLogger
  class Base
    # Class name to be logged
    attr_accessor :name, :filter

    # Set the logging level for this logger
    #
    # Note: This level is only for this particular instance. It does not override
    #   the log level in any logging instance or the default log level
    #   SemanticLogger.default_level
    #
    # Must be one of the values in SemanticLogger::LEVELS, or
    # nil if this logger instance should use the global default level
    def level=(level)
      @level_index = SemanticLogger.level_to_index(level)
      @level       = SemanticLogger.send(:index_to_level, @level_index)
    end

    # Returns the current log level if set, otherwise it returns the global
    # default log level
    def level
      @level || SemanticLogger.default_level
    end

    # Implement the log level calls
    #   logger.debug(message, hash|exception=nil, &block)
    #
    # Implement the log level query
    #   logger.debug?
    #
    # Parameters:
    #   message
    #     [String] text message to be logged
    #     Should always be supplied unless the result of the supplied block returns
    #     a string in which case it will become the logged message
    #     Default: nil
    #
    #   payload
    #     [Hash|Exception] Optional hash payload or an exception to be logged
    #     Default: nil
    #
    #   exception
    #     [Exception] Optional exception to be logged
    #     Allows both an exception and a payload to be logged
    #     Default: nil
    #
    # Examples:
    #    require 'semantic_logger'
    #
    #    # Enable trace level logging
    #    SemanticLogger.default_level = :info
    #
    #    # Log to screen
    #    SemanticLogger.add_appender(io: STDOUT, formatter: :color)
    #
    #    # And log to a file at the same time
    #    SemanticLogger.add_appender(file_name: 'application.log', formatter: :color)
    #
    #    logger = SemanticLogger['MyApplication']
    #    logger.debug("Only display this if log level is set to Debug or lower")
    #
    #    # Log semantic information along with a text message
    #    logger.info("Request received", user: "joe", duration: 100)
    #
    #    # Log an exception in a semantic way
    #    logger.info("Parsing received XML", exc)
    #
    SemanticLogger::LEVELS.each_with_index do |level, index|
      class_eval <<-EOT, __FILE__, __LINE__ + 1
        def #{level}(message=nil, payload=nil, exception=nil, &block)
          if level_index <= #{index}
            log_internal(:#{level}, #{index}, message, payload, exception, &block)
            true
          else
            false
          end
        end

        def #{level}?
          level_index <= #{index}
        end

        def measure_#{level}(message, params = {}, &block)
          if level_index <= #{index}
            measure_internal(:#{level}, #{index}, message, params, &block)
          else
            block.call(params) if block
          end
        end

        def benchmark_#{level}(message, params = {}, &block)
          if level_index <= #{index}
            measure_internal(:#{level}, #{index}, message, params, &block)
          else
            block.call(params) if block
          end
        end
      EOT
    end

    # Dynamically supply the log level with every measurement call
    def measure(level, message, params = {}, &block)
      index = SemanticLogger.level_to_index(level)
      if level_index <= index
        measure_internal(level, index, message, params, &block)
      else
        block.call(params) if block
      end
    end

    # Backward compatibility
    alias_method :benchmark, :measure

    # Log a thread backtrace
    def backtrace(thread: Thread.current, level: :warn, message: 'Backtrace:', payload: nil, metric: nil, metric_amount: 1)
      log       = Log.new(name, level)
      backtrace =
        if thread == Thread.current
          self.class.cleanse_backtrace
        else
          log.thread_name = thread.name
          log.tags        = thread[:semantic_logger_tags].clone
          log.named_tags  = thread[:semantic_logger_named_tags].clone
          thread.backtrace
        end
      # TODO: Keep backtrace instead of transforming into a text message at this point
      # Maybe log_backtrace: true
      if backtrace
        message += "\n"
        message << backtrace.join("\n")
      end

      if log.assign(message: message, backtrace: backtrace, payload: payload, metric: metric, metric_amount: metric_amount) && should_log?(log)
        self.log(log)
      end
    end

    # :nodoc:
    def tagged(*tags, &block)
      SemanticLogger.tagged(*tags, &block)
    end

    # :nodoc:
    alias_method :with_tags, :tagged

    # :nodoc:
    def tags
      SemanticLogger.tags
    end

    # :nodoc:
    def push_tags(*tags)
      SemanticLogger.push_tags(*tags)
    end

    # :nodoc:
    def pop_tags(quantity = 1)
      SemanticLogger.pop_tags(quantity)
    end

    # :nodoc:
    def silence(new_level = :error, &block)
      SemanticLogger.silence(new_level, &block)
    end

    # :nodoc:
    def fast_tag(tag, &block)
      SemanticLogger.fast_tag(tag, &block)
    end

    # :nodoc:
    def with_payload(payload, &block)
      warn '#with_payload is deprecated, use SemanticLogger.named_tagged'
      SemanticLogger.named_tagged(payload, &block)
    end

    # :nodoc:
    def payload
      warn '#payload is deprecated, use SemanticLogger.named_tags'
      SemanticLogger.named_tags
    end

    protected

    # Write log data to underlying data storage
    def log(log_)
      raise NotImplementedError.new('Logging Appender must implement #log(log)')
    end

    private

    # Initializer for Abstract Class SemanticLogger::Base
    #
    # Parameters
    #  klass [String]
    #   Name of the class, module, or other identifier for which the log messages
    #   are being logged
    #
    #  level [Symbol]
    #    Only allow log entries of this level or higher to be written to this appender
    #    For example if set to :warn, this appender would only log :warn and :fatal
    #    log messages when other appenders could be logging :info and lower
    #
    #  filter [Regexp|Proc]
    #    RegExp: Only include log messages where the class name matches the supplied
    #    regular expression. All other messages will be ignored
    #    Proc: Only include log messages where the supplied Proc returns true
    #          The Proc must return true or false
    def initialize(klass, level = nil, filter = nil)
      # Support filtering all messages to this logger using a Regular Expression or Proc
      raise ':filter must be a Regexp or Proc' unless filter.nil? || filter.is_a?(Regexp) || filter.is_a?(Proc)

      @filter = filter.is_a?(Regexp) ? filter.freeze : filter
      @name   = klass.is_a?(String) ? klass : klass.name
      if level.nil?
        # Allow the global default level to determine this loggers log level
        @level_index = nil
        @level       = nil
      else
        self.level = level
      end
    end

    # Return the level index for fast comparisons
    # Returns the global default level index if the level has not been explicitly
    # set for this instance
    def level_index
      @level_index || SemanticLogger.default_level_index
    end

    # Whether to log the supplied message based on the current filter if any
    def include_message?(log)
      return true if @filter.nil?

      if @filter.is_a?(Regexp)
        (@filter =~ log.name) != nil
      elsif @filter.is_a?(Proc)
        @filter.call(log) == true
      end
    end

    # Whether the log message should be logged for the current logger or appender
    def should_log?(log)
      # Ensure minimum log level is met, and check filter
      (level_index <= (log.level_index || 0)) && include_message?(log)
    end

    # Log message at the specified level
    def log_internal(level, index, message = nil, payload = nil, exception = nil, &block)
      log        = Log.new(name, level, index)
      should_log =
        if payload.nil? && exception.nil? && message.is_a?(Hash)
          log.assign(message)
        else
          log.assign_positional(message, payload, exception, &block)
        end

      self.log(log) if should_log && include_message?(log)
    end

    # Measure the supplied block and log the message
    def measure_internal(level, index, message, params)
      exception = nil
      result    = nil
      # Single parameter is a hash
      if params.empty? && message.is_a?(Hash)
        params  = message
        message = nil
      end
      start = Time.now
      begin
        if block_given?
          result =
            if silence_level = params[:silence]
              # In case someone accidentally sets `silence: true` instead of `silence: :error`
              silence_level = :error if silence_level == true
              silence(silence_level) { yield(params) }
            else
              yield(params)
            end
        end
      rescue Exception => exc
        exception = exc
      ensure
        # Must use ensure block otherwise a `return` in the yield above will skip the log entry
        log       = Log.new(name, level, index)
        exception ||= params[:exception]
        message   = params[:message] if params[:message]
        duration  =
          if block_given?
            1000.0 * (Time.now - start)
          else
            params[:duration] || raise('Mandatory block missing when :duration option is not supplied')
          end

        # Extract options after block completes so that block can modify any of the options
        payload   = params[:payload]

        should_log = log.assign(
          message:            message,
          payload:            payload,
          min_duration:       params[:min_duration] || 0.0,
          exception:          exception,
          metric:             params[:metric],
          metric_amount:      1,
          duration:           duration,
          backtrace:          nil,
          log_exception:      params[:log_exception] || :partial,
          on_exception_level: params[:on_exception_level]
        )

        self.log(log) if should_log && include_message?(log)
        raise exception if exception
        result
      end
    end

  end
end
