require 'observer'
require 'pp'
require 'set'
require 'openssl'

module ShortBus
  class Service
    include DebugMessage

    attr_reader :name, :threads

    def initialize(
      debug: false,
      driver: nil,
      message_spec: nil,
      name: nil,
      recursive: false,
      publisher_spec: nil,
      service: nil, 
      suppress_exception: false,
      thread_count: 1
    )
      @debug = debug
      @driver = driver
      @message_spec = message_spec ? Spec.new(message_spec) : nil
      @recursive = recursive
      @publisher_spec = publisher_spec ? Spec.new(publisher_spec) : nil
      @service = service
      @thread_count = thread_count

      @name = name || @service.to_s || OpenSSL::HMAC.new(rand.to_s, 'sha1').to_s
      @run_queue = Queue.new
      @threads = []
      start
    end
    
    def check(*args)
      dry_run = (args.length > 0 && args[0] == :dry_run)
      args.reduce(false) do |acc, arg| 
        debug_message "[#{@name}]#check(#{message})"
        acc || if(
          arg.is_a?(ShortBus::Message) &&
          (!@message_spec || @message_spec.match(message.to_s)) &&
          (!@publisher_spec || @publisher_spec.match(message.publisher)) &&
          (message.publisher != @name || @recursive)
        )
          @run_queue << message unless dry_run
        end
      end
    end

    # TODO: consider some mechanism to pass Exceptions up to the main thread,
    #   perhaps with a whitelist, optional logging, something clean.
    #
    def service_thread
      Thread.new do 
        begin
          run_service @run_queue.shift until Thread.current.key?(:stop) 
        rescue Exception => exc
          puts "Service [#{@name}] => #{exc.inspect}" unless @suppress_exception
          abort if exc.is_a? SystemExit
          retry unless Thread.current.key?(:stop)
        end 
      end 
    end

    def start
      @threads << service_thread while @threads.length < @thread_count
    end

    def stop(when=nil)
      @threads.each do |thread|
        if when.is_a? Numeric
          begin
            Timeout.timeout(when) { stop }
          rescue Timeout::Error
            stop :now
          end
        elsif when == :now   
          thread.kill
        else
          thread[:stop] = true
        end
      end
      @threads.delete_if { |thread| @threads[index].join }
    end

    def stop!
      stop :now
    end

    def to_s
      @name
    end

    private

    def run_service(message)
      debug_message "[#{@name}]#run_service(#{message}) -> #{@service.class.name} ##{@service.arity}"
      if @service.is_a?(Proc) || @service.is_a?(Method)
        if @service.arity == 0
          @driver.publish(message: @service.call, publisher: @name)
        elsif [1, -1, -2].include? @service.arity
          @driver.publish(message: @service.call(message), publisher: @name)
        else
          raise ArgumentError, "Service invalid arg count: #{@service.class.name}"
        end
      else
        raise ArgumentError, "Unknown service type: #{@service.class.name}"
      end
    end
  end
end
