#
# Fluentd
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.
#

require 'fcntl'

require 'cool.io'
require 'yajl'

require 'fluent/input'

module Fluent
  class ForwardInput < Input
    Plugin.register_input('forward', self)

    LISTEN_PORT = 24224

    def initialize
      super
      require 'fluent/plugin/socket_util'
    end

    desc 'The port to listen to.'
    config_param :port, :integer, default: LISTEN_PORT
    desc 'The bind address to listen to.'
    config_param :bind, :string, default: '0.0.0.0'
    config_param :backlog, :integer, default: nil
    # SO_LINGER 0 to send RST rather than FIN to avoid lots of connections sitting in TIME_WAIT at src
    desc 'The timeout time used to set linger option.'
    config_param :linger_timeout, :integer, default: 0
    # This option is for Cool.io's loop wait timeout to avoid loop stuck at shutdown. Almost users don't need to change this value.
    config_param :blocking_timeout, :time, default: 0.5

    desc 'Log warning if received chunk size is larger than this value.'
    config_param :chunk_size_warn_limit, :size, default: nil
    desc 'Received chunk is dropped if it is larger than this value.'
    config_param :chunk_size_limit, :size, default: nil
    desc 'Skip an event if incoming event is invalid.'
    config_param :skip_invalid_event, :bool, default: false
    desc "The field name of the client's hostname."
    config_param :source_host_key, :string, default: nil

    def configure(conf)
      super
    end

    def start
      super

      @loop = Coolio::Loop.new

      socket_manager_path = ENV['SERVERENGINE_SOCKETMANAGER_PATH']
      if Fluent.windows?
        socket_manager_path = socket_manager_path.to_i
      end
      client = ServerEngine::SocketManager::Client.new(socket_manager_path)

      @lsock = listen(client)
      @loop.attach(@lsock)

      @usock = client.listen_udp(@bind, @port)
      @usock.fcntl(Fcntl::F_SETFL, Fcntl::O_NONBLOCK)
      @hbr = HeartbeatRequestHandler.new(@usock, method(:on_heartbeat_request))
      @loop.attach(@hbr)

      @thread = Thread.new(&method(:run))
    end

    def shutdown
      # In test cases it occasionally appeared that when detaching a watcher, another watcher is also detached.
      # In the case in the iteration of watchers, a watcher that has been already detached is intended to be detached
      # and therfore RuntimeError occurs saying that it is not attached to a loop.
      # It occures only when testing for sending responses to ForwardOutput.
      # Sending responses needs to write the socket that is previously used only to read
      # and a handler has 2 watchers that is used to read and to write.
      # This problem occurs possibly because those watchers are thought to be related to each other
      # and when detaching one of them the other is also detached for some reasons.
      # As a workaround, check if watchers are attached before detaching them.
      @loop.watchers.each {|w| w.detach if w.attached? }
      @loop.stop
      @usock.close
      @thread.join
      @lsock.close

      super
    end

    def listen(client)
      log.info "listening fluent socket on #{@bind}:#{@port}"
      sock = client.listen_tcp(@bind, @port)
      s = Coolio::TCPServer.new(sock, nil, Handler, @linger_timeout, log, method(:on_message))
      s.listen(@backlog) unless @backlog.nil?
      s
    end

    #config_param :path, :string, :default => DEFAULT_SOCKET_PATH
    #def listen
    #  if File.exist?(@path)
    #    File.unlink(@path)
    #  end
    #  FileUtils.mkdir_p File.dirname(@path)
    #  log.debug "listening fluent socket on #{@path}"
    #  Coolio::UNIXServer.new(@path, Handler, method(:on_message))
    #end

    def run
      @loop.run(@blocking_timeout)
    rescue => e
      log.error "unexpected error", error: e
      log.error_backtrace
    end

    private

    # message Entry {
    #   1: long time
    #   2: object record
    # }
    #
    # message Forward {
    #   1: string tag
    #   2: list<Entry> entries
    #   3: object option (optional)
    # }
    #
    # message PackedForward {
    #   1: string tag
    #   2: raw entries  # msgpack stream of Entry
    #   3: object option (optional)
    # }
    #
    # message Message {
    #   1: string tag
    #   2: long? time
    #   3: object record
    #   4: object option (optional)
    # }
    def on_message(msg, chunk_size, peeraddr)
      if msg.nil?
        # for future TCP heartbeat_request
        return
      end

      # TODO: raise an exception if broken chunk is generated by recoverable situation
      unless msg.is_a?(Array)
        log.warn "incoming chunk is broken:", source: source_message(peeraddr), msg: msg
        return
      end

      tag = msg[0]
      entries = msg[1]

      if @chunk_size_limit && (chunk_size > @chunk_size_limit)
        log.warn "Input chunk size is larger than 'chunk_size_limit', dropped:", tag: tag, source: source_message(peeraddr), limit: @chunk_size_limit, size: chunk_size
        return
      elsif @chunk_size_warn_limit && (chunk_size > @chunk_size_warn_limit)
        log.warn "Input chunk size is larger than 'chunk_size_warn_limit':", tag: tag, source: source_message(peeraddr), limit: @chunk_size_warn_limit, size: chunk_size
      end

      if entries.class == String
        # PackedForward
        option = msg[2]
        size = (option && option['size']) || 0
        es = MessagePackEventStream.new(entries, nil, size.to_i)
        es = check_and_skip_invalid_event(tag, es, peeraddr) if @skip_invalid_event
        es = add_source_host(es, peeraddr[2]) if @source_host_key
        router.emit_stream(tag, es)

      elsif entries.class == Array
        # Forward
        es = if @skip_invalid_event
               check_and_skip_invalid_event(tag, entries, peeraddr)
             else
               es = MultiEventStream.new
               entries.each { |e|
                 record = e[1]
                 next if record.nil?
                 time = e[0]
                 time = (now ||= Engine.now) if time.to_i == 0
                 es.add(time, record)
               }
               es
             end
        es = add_source_host(es, peeraddr[2]) if @source_host_key
        router.emit_stream(tag, es)
        option = msg[2]

      else
        # Message
        time = msg[1]
        record = msg[2]
        if @skip_invalid_event && invalid_event?(tag, time, record)
          log.warn "got invalid event and drop it:", source: source_message(peeraddr), tag: tag, time: time, record: record
          return msg[3] # retry never succeeded so return ack and drop incoming event.
        end
        return if record.nil?
        time = Engine.now if time.to_i == 0
        record[@source_host_key] = peeraddr[2] if @source_host_key
        router.emit(tag, time, record)
        option = msg[3]
      end

      # return option for response
      option
    end

    def invalid_event?(tag, time, record)
      !((time.is_a?(Integer) || time.is_a?(::Fluent::EventTime)) && record.is_a?(Hash) && tag.is_a?(String))
    end

    def check_and_skip_invalid_event(tag, es, peeraddr)
      new_es = MultiEventStream.new
      es.each { |time, record|
        if invalid_event?(tag, time, record)
          log.warn "skip invalid event:", source: source_message(peeraddr), tag: tag, time: time, record: record
          next
        end
        new_es.add(time, record)
      }
      new_es
    end

    def add_source_host(es, host)
      new_es = MultiEventStream.new
      es.each { |time, record|
        record[@source_host_key] = host
        new_es.add(time, record)
      }
      new_es
    end

    def source_message(peeraddr)
      _, port, host, addr = peeraddr
      "host: #{host}, addr: #{addr}, port: #{port}"
    end

    class Handler < Coolio::Socket
      PEERADDR_FAILED = ["?", "?", "name resolusion failed", "?"]

      def initialize(io, linger_timeout, log, on_message)
        super(io)

        @peeraddr = nil
        if io.is_a?(TCPSocket) # for unix domain socket support in the future
          @peeraddr = (io.peeraddr rescue PEERADDR_FAILED)
          opt = [1, linger_timeout].pack('I!I!')  # { int l_onoff; int l_linger; }
          io.setsockopt(Socket::SOL_SOCKET, Socket::SO_LINGER, opt)
        end

        @chunk_counter = 0
        @on_message = on_message
        @log = log
        @log.trace {
          begin
            remote_port, remote_addr = *Socket.unpack_sockaddr_in(@_io.getpeername)
          rescue
            remote_port = nil
            remote_addr = nil
          end
          "accepted fluent socket from '#{remote_addr}:#{remote_port}': object_id=#{self.object_id}"
        }
      end

      def on_connect
      end

      def on_read(data)
        first = data[0]
        if first == '{' || first == '['
          m = method(:on_read_json)
          @serializer = :to_json.to_proc
          @y = Yajl::Parser.new
          @y.on_parse_complete = lambda { |obj|
            option = @on_message.call(obj, @chunk_counter, @peeraddr)
            respond option
            @chunk_counter = 0
          }
        else
          m = method(:on_read_msgpack)
          @serializer = :to_msgpack.to_proc
          @u = Fluent::Engine.msgpack_factory.unpacker
        end

        (class << self; self; end).module_eval do
          define_method(:on_read, m)
        end
        m.call(data)
      end

      def on_read_json(data)
        @chunk_counter += data.bytesize
        @y << data
      rescue => e
        @log.error "forward error", error: e, error_class: e.class
        @log.error_backtrace
        close
      end

      def on_read_msgpack(data)
        @chunk_counter += data.bytesize
        @u.feed_each(data) do |obj|
          option = @on_message.call(obj, @chunk_counter, @peeraddr)
          respond option if option
          @chunk_counter = 0
        end
      rescue => e
        @log.error "forward error", error: e, error_class: e.class
        @log.error_backtrace
        close
      end

      def respond(option)
        if option && option['chunk']
          res = { 'ack' => option['chunk'] }
          write @serializer.call(res)
          @log.trace { "sent response to fluent socket" }
        end
      end

      def on_close
        @log.trace { "closed socket" }
      end
    end

    class HeartbeatRequestHandler < Coolio::IO
      def initialize(io, callback)
        super(io)
        @io = io
        @callback = callback
      end

      def on_readable
        begin
          msg, addr = @io.recvfrom(1024)
        rescue Errno::EAGAIN, Errno::EWOULDBLOCK, Errno::EINTR
          return
        end
        host = addr[3]
        port = addr[1]
        @callback.call(host, port, msg)
      rescue
        # TODO log?
      end
    end

    def on_heartbeat_request(host, port, msg)
      #log.trace "heartbeat request from #{host}:#{port}"
      begin
        @usock.send "\0", 0, host, port
      rescue Errno::EAGAIN, Errno::EWOULDBLOCK, Errno::EINTR
      end
    end
  end
end
