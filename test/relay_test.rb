# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'minitest/autorun'
require 'net/smtp'
require 'net/http'
require 'socket'
require 'stringio'
require 'smtp_relay'

Thread.report_on_exception = false

FROM = 'alertmanager@reenchree.dev'

class RelayTest < Minitest::Test
  def setup
    @ses = Aws::SESV2::Client.new(region: 'us-west-2', stub_responses: true,
                                  credentials: Aws::Credentials.new('test', 'test'))
    @ses.stub_responses(:send_email, { message_id: 'msg-1' })
    @log = StringIO.new
    @server = build_server
    @server.start
    @port = @server.ports.first.split(':').last.to_i
  end

  def teardown
    @server.stop(wait_seconds_before_close: 0, gracefully: false)
  end

  def build_server(cidrs: ['127.0.0.0/8'], max_bytes: 2048, max_recipients: 50)
    SmtpRelay::Server.new(ses: @ses, allowed_cidrs: cidrs, from_domain: 'reenchree.dev',
                          max_bytes: max_bytes, max_recipients: max_recipients,
                          logger: Logger.new(@log), hosts: '127.0.0.1', ports: free_port.to_s,
                          max_processings: 8)
  end

  def free_port
    s = TCPServer.new('127.0.0.1', 0)
    s.addr[1]
  ensure
    s&.close
  end

  def mail_msg(subject: 'test', body: 'hello')
    "From: Alertmanager <#{FROM}>\r\nTo: chris@example.com\r\nSubject: #{subject}\r\n\r\n#{body}\r\n"
  end

  def smtp_send(from: FROM, to: ['chris@example.com'], msg: mail_msg)
    Net::SMTP.start('127.0.0.1', @port, helo: 'test.local') { |s| s.send_message(msg, from, *to) }
  end

  # Raw dialog for protocol edge cases: returns the reply line for each command.
  def dialog(*cmds)
    sock = TCPSocket.new('127.0.0.1', @port)
    replies = [read_reply(sock)]
    cmds.each do |c|
      sock.write("#{c.delete_prefix('#')}\r\n")
      replies << read_reply(sock) unless c.start_with?('#')
    end
    replies
  ensure
    sock&.close
  end

  def read_reply(sock)
    line = sock.gets.to_s
    line = sock.gets.to_s while line[3] == '-'
    line.strip
  end

  def sent_requests
    @ses.api_requests.select { |r| r[:operation_name] == :send_email }.map { |r| r[:params] }
  end

  def assert_smtp_error(code, &blk)
    err = assert_raises(Net::SMTPError, &blk)
    assert_equal code, err.response.status, err.message
  end

  # --- envelope and protocol ---

  def test_happy_path_forwards_raw_bytes_and_envelope_rcpts_including_bcc
    msg = mail_msg
    smtp_send(to: ['chris@example.com', 'hidden-bcc@example.com'], msg: msg)
    req = sent_requests.fetch(0)
    assert_equal FROM, req[:from_email_address]
    assert_equal ['chris@example.com', 'hidden-bcc@example.com'], req[:destination][:to_addresses]
    assert_equal msg.chomp("\r\n"), req[:content][:raw][:data]
    assert_equal 1, @server.metrics['sent']
    assert_match(/sent from=#{FROM} rcpts=2 .*message_id=msg-1/, @log.string)
  end

  def test_brackets_and_mail_params_are_stripped
    replies = dialog('EHLO t', "MAIL FROM:<#{FROM}> SIZE=100", 'RCPT TO:<a@example.com>',
                     'DATA', '#Subject: x', '#', '#hi', '.', 'QUIT')
    assert_equal '250', replies[5][0, 3], replies.inspect
    assert_equal FROM, sent_requests.fetch(0)[:from_email_address]
    assert_equal ['a@example.com'], sent_requests.fetch(0)[:destination][:to_addresses]
  end

  def test_sender_domain_is_case_insensitive
    smtp_send(from: 'AlertManager@ReEnchree.DEV')
    assert_equal 1, sent_requests.size
  end

  def test_wrong_sender_domain_is_550
    assert_smtp_error('550') { smtp_send(from: 'x@gmail.com') }
    assert_smtp_error('550') { smtp_send(from: 'x@reenchree.dev.evil.com') }
    assert_smtp_error('550') { smtp_send(from: 'x@evil@reenchree.dev') }
    assert_empty sent_requests
  end

  def test_null_sender_is_550
    replies = dialog('HELO t', 'MAIL FROM:<>', 'QUIT')
    assert_equal '550', replies[2][0, 3]
  end

  def test_rcpt_before_mail_is_503
    replies = dialog('HELO t', 'RCPT TO:<a@example.com>', 'QUIT')
    assert_equal '503', replies[2][0, 3]
  end

  def test_recipient_cap_is_452
    rcpts = (1..51).map { |i| "r#{i}@example.com" }
    assert_smtp_error('452') { smtp_send(to: rcpts) }
    smtp_send(to: rcpts.first(50))
    assert_equal 50, sent_requests.fetch(0)[:destination][:to_addresses].size
  end

  def test_multiple_messages_on_one_connection
    Net::SMTP.start('127.0.0.1', @port, helo: 't') do |s|
      s.send_message(mail_msg(subject: 'one'), FROM, 'a@example.com')
      s.send_message(mail_msg(subject: 'two'), FROM, 'b@example.com')
    end
    assert_equal [['a@example.com'], ['b@example.com']],
                 sent_requests.map { |r| r[:destination][:to_addresses] }
  end

  # --- SES responses: never 250 without a MessageId ---

  def test_throttling_is_451
    @ses.stub_responses(:send_email, 'TooManyRequestsException')
    assert_smtp_error('451') { smtp_send }
    assert_equal 1, @server.metrics['ses_retryable']
    assert_equal 0, @server.metrics['sent']
  end

  def test_ses_internal_error_is_451
    @ses.stub_responses(:send_email, { status_code: 500, headers: {}, body: '' })
    assert_smtp_error('451') { smtp_send }
  end

  def test_network_error_is_451
    @ses.stub_responses(:send_email, Seahorse::Client::NetworkingError.new(Errno::ECONNREFUSED.new))
    assert_smtp_error('451') { smtp_send }
  end

  def test_missing_credentials_is_451
    @ses.stub_responses(:send_email, Aws::Errors::MissingCredentialsError.new('none'))
    assert_smtp_error('451') { smtp_send }
  end

  def test_empty_message_id_is_451
    @ses.stub_responses(:send_email, { message_id: '' })
    assert_smtp_error('451') { smtp_send }
    assert_equal 0, @server.metrics['sent']
  end

  def test_message_rejected_is_554
    @ses.stub_responses(:send_email, 'MessageRejected')
    assert_smtp_error('554') { smtp_send }
    assert_equal 1, @server.metrics['ses_permanent']
  end

  def test_access_denied_is_554
    @ses.stub_responses(:send_email, 'AccessDeniedException')
    assert_smtp_error('554') { smtp_send }
  end

  def test_unverified_from_domain_is_554
    @ses.stub_responses(:send_email, 'MailFromDomainNotVerifiedException')
    assert_smtp_error('554') { smtp_send }
  end

  # --- size and connection ---

  def test_oversize_is_552_without_ses_call_and_session_stays_usable
    big = mail_msg(body: "#{'x' * 100}\r\n" * 40)
    sock = TCPSocket.new('127.0.0.1', @port)
    read_reply(sock)
    ["HELO t", "MAIL FROM:<#{FROM}>", 'RCPT TO:<a@example.com>', 'DATA'].each do |c|
      sock.write("#{c}\r\n")
      read_reply(sock)
    end
    sock.write(big.gsub(/^\./, '..'))
    sock.write(".\r\n")
    assert_equal '552', read_reply(sock)[0, 3]
    sock.write("NOOP\r\n")
    assert_equal '250', read_reply(sock)[0, 3]
    sock.write("QUIT\r\n")
    assert_equal '221', read_reply(sock)[0, 3]
    sock.close
    assert_empty sent_requests
    assert_equal 1, @server.metrics['rejected']
    smtp_send # next message after a rejection still goes through
    assert_equal 1, sent_requests.size
  end

  def test_disallowed_peer_is_421
    teardown
    @server = build_server(cidrs: ['10.42.0.0/16'])
    @server.start
    @port = @server.ports.first.split(':').last.to_i
    assert_equal '421', dialog.first[0, 3]
    assert_equal 1, @server.metrics['rejected']
  end

  def test_peer_matching_handles_ipv4_mapped_and_garbage
    srv = build_server(cidrs: ['10.42.0.0/16'])
    assert srv.allowed_peer?('10.42.3.7')
    assert srv.allowed_peer?('::ffff:10.42.3.7')
    refute srv.allowed_peer?('10.43.0.1')
    refute srv.allowed_peer?('::1')
    refute srv.allowed_peer?('not-an-ip')
  end

  def test_two_concurrent_sessions
    threads = 2.times.map { |i| Thread.new { smtp_send(to: ["c#{i}@example.com"]) } }
    threads.each(&:join)
    assert_equal 2, sent_requests.size
  end

  # --- content ---

  def test_dot_stuffing_and_utf8_round_trip
    body = ".leading dot\r\n..two dots\r\nnaïve café 🚀"
    msg = "From: #{FROM}\r\nSubject: =?UTF-8?B?w6k=?=\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n#{body}\r\n"
    smtp_send(msg: msg)
    data = sent_requests.fetch(0)[:content][:raw][:data]
    assert_equal msg.chomp("\r\n").b, data.b
  end

  # --- http ---

  def test_healthz_and_metrics
    http = SmtpRelay::HTTP.new(server: @server, port: 0, host: '127.0.0.1').start
    smtp_send
    @ses.stub_responses(:send_email, 'MessageRejected')
    assert_raises(Net::SMTPError) { smtp_send }
    assert_equal '200', Net::HTTP.get_response(URI("http://127.0.0.1:#{http.port}/healthz")).code
    metrics = Net::HTTP.get(URI("http://127.0.0.1:#{http.port}/metrics"))
    assert_includes metrics, 'smtp_relay_messages_total{result="sent"} 1'
    assert_includes metrics, 'smtp_relay_messages_total{result="ses_permanent"} 1'
  ensure
    http&.stop
  end
end
