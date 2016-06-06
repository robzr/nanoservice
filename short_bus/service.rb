require 'observer'
require 'pp'
require 'set'
require 'openssl'

module ShortBus

  class ServiceThreadDone < StandardError
  end

  class Service
    include DebugMessage
    CLASS_NAME = "Service"

    attr_reader :name, :run_count, :threads

    def initialize(
      debug: false,
      driver: nil,
      event_spec: nil,
      name: nil,
      recursive: false,
      sender_spec: nil,
      service: nil, 
      thread_count: 1
    )
      @debug = debug
      @driver = driver
      @event_spec = event_spec ? Spec.new(event_spec) : nil
      @recursive = recursive
      @sender_spec = sender_spec ? Spec.new(sender_spec) : nil
      @service = service
      @thread_count = thread_count

      @name = name || @service.to_s || OpenSSL::HMAC.new(rand.to_s, 'sha1').to_s
      @run_queue = Queue.new
      @run_count = 0
      @thread_launcher = nil
      @threads = []
      start
    end
    
    def check(message)
      debug_message "[#{@name}]#check(#{message})"
      if match_event message.event
        if match_sender message.sender
          @run_queue << message if message.sender != @name || @recursive
        end
      end
    end

    def service_thread
      Thread.new do 
        begin
          loop { run_service @run_queue.shift }
        rescue Exception => e
          # TODO: add optional exception reporting/upstream raising
          puts "[#{@name}]service_thread => #{e.inspect}"
        ensure
          if @thread_launcher
            @thread_launcher.raise(ServiceThreadDone, Thread.current)
          end
        end 
      end 
    end

    def start
      @thread_launcher = Thread.new do 
        loop do 
          begin
            @threads.delete_if { |thread| !thread.alive? }
            @threads << service_thread while @threads.length < @thread_count
            sleep
          rescue ShortBus::ServiceThreadDone => exc
            debug_message "[#{@name}]#start ServiceThreadDone => #{exc.inspect}"
          rescue Exception => exc
            puts "Service::start Exception: #{exc.inspect}"
          end
        end
      end
    end

    def stop
      if @thread_launcher
        @thread_launcher.kill if @thread_launcher.alive?
        @threads.each_index do |index|
          @threads[index].kill
          @threads[index].join
          @threads.delete index
        end
        @thread_launcher.join
        @thread_launcher = nil
      end
    end

    private

    def match_event(event)
      if @event_spec
        @event_spec.match event
      else
        true
      end
    end

    def match_sender(sender)
      if @sender_spec
        @sender_spec.match sender
      else
        true
      end
    end

    def run_service(message)
      @run_count += 1
      debug_message "[#{@name}]#run_service(#{message}) -> #{@service.class.name} ##{@service.arity}"
      case @service.class.name
      when 'Method', 'Proc'
        if @service.arity == 0
          @driver.send(message: @service.call, sender: @name)
        elsif [1, -1, -2].include? @service.arity
          @driver.send(message: @service.call(message), sender: @name)
        else
          raise ArgumentError, "Service invalid arg count: #{@service.class.name}"
        end
      else
        raise ArgumentError, "Unknown service type: #{@service.class.name}"
      end
    end
  end
end
