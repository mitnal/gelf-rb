require 'helper'

RANDOM_DATA = ('A'..'Z').to_a

class TestNotifier < Test::Unit::TestCase
  should "allow access to host, port, max_chunk_size and default_options" do
    Socket.expects(:gethostname).returns('default_hostname')
    n = GELF::Notifier.new
    assert_equal ['localhost', 12201, 1420], [n.host, n.port, n.max_chunk_size]
    assert_equal( { '_version' => '1.0', '_level' => GELF::DEBUG,
                    '_host' => 'default_hostname', '_facility' => 'gelf-rb' },
                  n.default_options )
    n.host, n.port, n.max_chunk_size, n.default_options = 'graylog2.org', 7777, :lan, {'_host' => 'grayhost'}
    assert_equal ['graylog2.org', 7777, 8154], [n.host, n.port, n.max_chunk_size]
    assert_equal({'_host' => 'grayhost'}, n.default_options)

    n.max_chunk_size = 1337.1
    assert_equal 1337, n.max_chunk_size
  end

  context "with notifier with mocked sender" do
    setup do
      Socket.stubs(:gethostname).returns('stubbed_hostname')
      @notifier = GELF::Notifier.new('host', 12345)
      @sender = mock
      @notifier.instance_variable_set('@sender', @sender)
    end

    context "extract_hash" do
      should "check arguments" do
        assert_raise(ArgumentError) { @notifier.__send__(:extract_hash) }
        assert_raise(ArgumentError) { @notifier.__send__(:extract_hash, 1, 2, 3) }
      end

      should "work with hash" do
        hash = @notifier.__send__(:extract_hash, { '_version' => '1.0', '_short_message' => 'message' })
        assert_equal '1.0', hash['_version']
        assert_equal 'message', hash['_short_message']
      end

      should "work with any object which responds to #to_hash" do
        o = Object.new
        o.expects(:to_hash).returns({ '_version' => '1.0', '_short_message' => 'message' })
        hash = @notifier.__send__(:extract_hash, o)
        assert_equal '1.0', hash['_version']
        assert_equal 'message', hash['_short_message']
      end

      should "work with exception with backtrace" do
        e = RuntimeError.new('message')
        e.set_backtrace(caller)
        hash = @notifier.__send__(:extract_hash, e)
        assert_equal 'RuntimeError: message', hash['_short_message']
        assert_match /Backtrace/, hash['_full_message']
        assert_equal GELF::ERROR, hash['_level']
      end

      should "work with exception without backtrace" do
        e = RuntimeError.new('message')
        hash = @notifier.__send__(:extract_hash, e)
        assert_match /Backtrace is not available/, hash['_full_message']
      end

      should "work with exception and hash" do
        e, h = RuntimeError.new('message'), {'param' => 1, '_level' => GELF::FATAL, '_short_message' => 'will be hidden by exception'}
        hash = @notifier.__send__(:extract_hash, e, h)
        assert_equal 'RuntimeError: message', hash['_short_message']
        assert_equal GELF::FATAL, hash['_level']
        assert_equal 1, hash['param']
      end

      should "work with plain text" do
        hash = @notifier.__send__(:extract_hash, 'message')
        assert_equal 'message', hash['_short_message']
        assert_equal GELF::INFO, hash['_level']
      end

      should "work with plain text and hash" do
        hash = @notifier.__send__(:extract_hash, 'message', '_level' => GELF::WARN)
        assert_equal 'message', hash['_short_message']
        assert_equal GELF::WARN, hash['_level']
      end

      should "covert hash keys to strings" do
        hash = @notifier.__send__(:extract_hash, :_short_message => :message)
        assert hash.has_key?('_short_message')
        assert !hash.has_key?(:_short_message)
      end

      should "not overwrite keys on convert" do
        assert_raise(ArgumentError) { @notifier.__send__(:extract_hash, :_short_message => :message1, '_short_message' => 'message2') }
      end

      should "use default_options" do
        @notifier.default_options = {:foo => 'bar', '_short_message' => 'will be hidden by explicit argument', '_host' => 'some_host'}
        hash = @notifier.__send__(:extract_hash, { '_version' => '1.0', '_short_message' => 'message' })
        assert_equal 'bar', hash['foo']
        assert_equal 'message', hash['_short_message']
      end

      should "be compatible with HoptoadNotifier" do
        # https://github.com/thoughtbot/hoptoad_notifier/blob/master/README.rdoc, section Going beyond exceptions
        hash = @notifier.__send__(:extract_hash, :error_class => 'Class', :error_message => 'Message')
        assert_equal 'Class: Message', hash['_short_message']
      end

      should "set file and line" do
        line = __LINE__
        hash = @notifier.__send__(:extract_hash, { '_version' => '1.0', '_short_message' => 'message' })
        assert_match /test_notifier.rb/, hash['_file']
        assert_equal line + 1, hash['_line']
      end

      should "set timestamp" do
        hash = @notifier.__send__(:extract_hash, { '_version' => '1.0', '_short_message' => 'message' })
        now = Time.now.utc.to_i
        assert ((now - 1)..(now + 1)).include?(hash['_timestamp'])
      end
    end

    context "datagrams_from_hash" do
      should "not split short data" do
        @notifier.instance_variable_set('@hash', { '_version' => '1.0', '_short_message' => 'message' })
        datagrams = @notifier.__send__(:datagrams_from_hash)
        assert_equal 1, datagrams.count
        assert_equal "\x78\x9c", datagrams[0][0..1] # zlib header
      end

      should "split long data" do
        srand(1) # for stable tests
        hash = { '_version' => '1.0', '_short_message' => 'message' }
        hash.merge!('something' => (0..3000).map { RANDOM_DATA[rand(RANDOM_DATA.count)] }.join) # or it will be compressed too good
        @notifier.instance_variable_set('@hash', hash)
        datagrams = @notifier.__send__(:datagrams_from_hash)
        assert_equal 2, datagrams.count
        datagrams.each_index do |i|
          datagram = datagrams[i]
          assert datagram[0..1] == "\x1e\x0f" # chunked GELF magic number
          # datagram[2..9] is a message id
          assert_equal i, datagram[10].ord
          assert_equal datagrams.count, datagram[11].ord
        end
      end
    end

    context "level threshold" do
      setup do
        @notifier.level = GELF::WARN
        @hash = { '_version' => '1.0', '_short_message' => 'message' }
      end

      ['debug', 'DEBUG', :debug].each do |l|
        should "allow to set threshold as #{l.inspect}" do
          @notifier.level = l
          assert_equal GELF::DEBUG, @notifier.level
        end
      end

      should "not send notifications with level below threshold" do
        @sender.expects(:send_datagrams).never
        @notifier.notify!(@hash.merge('_level' => GELF::DEBUG))
      end

      should "not notifications with level equal or above threshold" do
        @sender.expects(:send_datagrams).once
        @notifier.notify!(@hash.merge('_level' => GELF::WARN))
      end
    end

    context "when disabled" do
      setup do
        @notifier.disable
      end

      should "not send datagrams" do
        @sender.expects(:send_datagrams).never
        @notifier.expects(:extract_hash).never
        @notifier.notify!({ '_version' => '1.0', '_short_message' => 'message' })
      end

      context "and enabled again" do
        setup do
          @notifier.enable
        end

        should "send datagrams" do
          @sender.expects(:send_datagrams)
          @notifier.notify!({ '_version' => '1.0', '_short_message' => 'message' })
        end
      end
    end

    should "pass valid data to sender" do
      @sender.expects(:send_datagrams).with do |datagrams|
        datagrams.is_a?(Array) && datagrams[0].is_a?(String)
      end
      @notifier.notify!({ '_version' => '1.0', '_short_message' => 'message' })
    end

    GELF::Levels.constants.each do |const|
      should "call notify with level #{const} from method name" do
        @notifier.expects(:notify_with_level).with(GELF.const_get(const), { '_version' => '1.0', '_short_message' => 'message' })
        @notifier.__send__(const.downcase, { '_version' => '1.0', '_short_message' => 'message' })
      end
    end

    should "not rescue from invalid invocation of #notify!" do
      assert_raise(ArgumentError) { @notifier.notify!(:no_short_message => 'too bad') }
    end

    should "rescue from invalid invocation of #notify" do
      @notifier.expects(:notify_with_level!).with(nil, instance_of(Hash)).raises(ArgumentError)
      @notifier.expects(:notify_with_level!).with(GELF::UNKNOWN, instance_of(ArgumentError))
      assert_nothing_raised { @notifier.notify(:no_short_message => 'too bad') }
    end
  end
end
