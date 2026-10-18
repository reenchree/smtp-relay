# frozen_string_literal: true

require 'midi-smtp-server'
require 'aws-sdk-sesv2'
require 'ipaddr'
require 'logger'
require 'webrick'

# In-cluster SMTP -> SES v2 API relay. Accepts plain SMTP from pod IPs and
# forwards the raw message with SendEmail, using whatever AWS credentials the
# default chain finds (IRSA web identity in the clusters).
module SmtpRelay
  # SES error codes that will never succeed on retry -> 5xx to the client.
  PERMANENT_SES_ERRORS = %w[
    MessageRejected
    MailFromDomainNotVerifiedException
    BadRequestException
    AccountSuspendedException
    NotFoundException
    AccessDeniedException
    AccessDenied
  ].freeze

  ADDRESS = /\A<?\s*([^<>\s]*)\s*>?/

  # Thread-safe counters rendered in Prometheus text format.
  class Metrics
    RESULTS = %w[sent ses_retryable ses_permanent rejected].freeze

    def initialize
      @mutex = Mutex.new
      @counts = RESULTS.to_h { |r| [r, 0] }
    end

    def inc(result)
      @mutex.synchronize { @counts[result] += 1 }
    end

    def [](result)
      @mutex.synchronize { @counts[result] }
    end

    def render
      lines = ['# HELP smtp_relay_messages_total Messages handled, by result.',
               '# TYPE smtp_relay_messages_total counter']
      @mutex.synchronize do
        @counts.each { |r, n| lines << %(smtp_relay_messages_total{result="#{r}"} #{n}) }
      end
      "#{lines.join("\n")}\n"
    end
  end

  # The SMTP side. Every hook either returns normally or raises an
  # Smtpd*Exception, which midi-smtp-server turns into the SMTP reply.
  class Server < MidiSmtpServer::Smtpd
    attr_reader :metrics

    def initialize(ses:, allowed_cidrs:, from_domain:, max_bytes:, max_recipients:, logger:, **smtpd_opts)
      @ses = ses
      @allowed = allowed_cidrs.map { |c| IPAddr.new(c) }
      @from_domain = from_domain.downcase
      @max_bytes = max_bytes
      @max_recipients = max_recipients
      @log = logger
      @metrics = Metrics.new
      super(**smtpd_opts)
    end

    # Route midi's logging to ours; expected SMTP rejections are already logged above.
    def on_logging_event(_ctx, severity, msg, err: nil)
      severity = Logger::DEBUG if err.is_a?(MidiSmtpServer::SmtpdException)
      @log.add(severity, msg)
    end

    def allowed_peer?(ip)
      addr = IPAddr.new(ip.to_s.sub(/\A::ffff:/i, ''))
      addr = addr.native if addr.ipv4_mapped?
      @allowed.any? { |net| net.family == addr.family && net.include?(addr) }
    rescue IPAddr::InvalidAddressError
      false
    end

    def on_connect_event(ctx)
      ip = ctx[:server][:remote_ip]
      return if allowed_peer?(ip)

      @metrics.inc('rejected')
      @log.warn("reject peer=#{ip} reason=cidr")
      raise MidiSmtpServer::Smtpd421Exception, 'peer not allowed'
    end

    # midi hands us the raw "<addr> PARAMS"; the return value becomes the envelope.
    def on_mail_from_event(_ctx, data)
      addr = data[ADDRESS, 1].to_s
      unless addr.downcase.end_with?("@#{@from_domain}") && addr.count('@') == 1
        @metrics.inc('rejected')
        @log.warn("reject from=#{addr.inspect} reason=sender_domain")
        raise MidiSmtpServer::Smtpd550Exception, "sender must be @#{@from_domain}"
      end
      addr
    end

    def on_rcpt_to_event(ctx, data)
      raise MidiSmtpServer::Smtpd452Exception, 'too many recipients' if ctx[:envelope][:to].size >= @max_recipients

      addr = data[ADDRESS, 1].to_s
      raise MidiSmtpServer::Smtpd501Exception, 'bad recipient' unless addr.match?(/\A[^@\s]+@[^@\s]+\z/)

      addr
    end

    # Never raise here: midi stays in DATA mode and the session desyncs.
    # Flag and drop the buffer instead; on_message_data_event rejects.
    def on_message_data_receiving_event(ctx)
      msg = ctx[:message]
      return if msg[:data].bytesize <= @max_bytes && !msg[:oversize]

      msg[:oversize] = true
      msg[:data].clear
    end

    def on_message_data_event(ctx)
      env = ctx[:envelope]
      msg = ctx[:message]
      if msg[:oversize]
        @metrics.inc('rejected')
        @log.warn("reject from=#{env[:from]} rcpts=#{env[:to].size} reason=size")
        raise MidiSmtpServer::Smtpd552Exception, "message exceeds #{@max_bytes} bytes"
      end

      deliver(env[:from], env[:to], msg[:data])
    end

    private

    def deliver(from, rcpts, data)
      resp = @ses.send_email(
        from_email_address: from,
        destination: { to_addresses: rcpts },
        content: { raw: { data: data } }
      )
      raise MidiSmtpServer::Smtpd451Exception, 'SES returned no MessageId' if resp.message_id.to_s.empty?

      @metrics.inc('sent')
      @log.info("sent from=#{from} rcpts=#{rcpts.size} bytes=#{data.bytesize} message_id=#{resp.message_id}")
    rescue Aws::Errors::ServiceError => e
      if PERMANENT_SES_ERRORS.include?(e.code)
        fail_with('ses_permanent', MidiSmtpServer::Smtpd554Exception, from, rcpts, data, e)
      else
        fail_with('ses_retryable', MidiSmtpServer::Smtpd451Exception, from, rcpts, data, e)
      end
    rescue MidiSmtpServer::SmtpdException
      @metrics.inc('ses_retryable')
      raise
    rescue StandardError => e
      fail_with('ses_retryable', MidiSmtpServer::Smtpd451Exception, from, rcpts, data, e)
    end

    def fail_with(result, exc, from, rcpts, data, err)
      @metrics.inc(result)
      code = err.respond_to?(:code) ? err.code : err.class.name
      @log.error("failed from=#{from} rcpts=#{rcpts.size} bytes=#{data.bytesize} result=#{result} error=#{code}")
      raise exc, "SES: #{code}"
    end
  end

  # /healthz and /metrics on a separate port.
  class HTTP
    def initialize(server:, port:, host: '0.0.0.0')
      @http = WEBrick::HTTPServer.new(BindAddress: host, Port: port,
                                      Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
      @http.mount_proc('/healthz') do |_req, res|
        res.status = server.stopped? ? 503 : 200
        res.body = res.status == 200 ? "ok\n" : "stopped\n"
      end
      @http.mount_proc('/metrics') do |_req, res|
        res['Content-Type'] = 'text/plain; version=0.0.4'
        res.body = server.metrics.render
      end
    end

    def port
      @http.config[:Port]
    end

    def start
      @thread = Thread.new { @http.start }
      self
    end

    def stop
      @http.shutdown
      @thread&.join
    end
  end

  def self.ses_client(region:)
    Aws::SESV2::Client.new(region: region, retry_limit: 2, http_open_timeout: 5,
                           http_read_timeout: 10)
  end
end
