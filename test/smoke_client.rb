# frozen_string_literal: true

# Container smoke scenarios; runs with the image's plain ruby (no bundler).
#   ruby smoke_client.rb RELAY_HOST FAKE_SES_HOST
require 'net/smtp'
require 'net/http'

relay, fake = ARGV
FROM = 'smoke@reenchree.dev'
failures = []

def mode(fake, m)
  Net::HTTP.post(URI("http://#{fake}:4566/_mode/#{m}"), '')
end

def send_mail(relay, from: FROM, body: 'smoke')
  msg = "From: #{from}\r\nTo: a@example.com\r\nSubject: smoke-marker\r\n\r\n#{body}\r\n"
  Net::SMTP.start(relay, 2525, helo: 'smoke') { |s| s.send_message(msg, from, 'a@example.com') }
  '250'
rescue Net::SMTPError => e
  e.response.status
end

check = lambda do |name, want, got|
  puts "#{got == want ? 'PASS' : 'FAIL'} #{name}: want #{want} got #{got}"
  failures << name unless got == want
end

mode(fake, 'ok')
check.call('ses ok -> 250', '250', send_mail(relay))
last = Net::HTTP.get(URI("http://#{fake}:4566/_last"))
check.call('fake SES received raw mail', true, last.include?('Subject: smoke-marker'))
mode(fake, 'error')
check.call('ses 500 -> 451', '451', send_mail(relay))
mode(fake, 'throttle')
check.call('ses throttle -> 451', '451', send_mail(relay))
mode(fake, 'ok')
check.call('wrong from -> 550', '550', send_mail(relay, from: 'x@gmail.com'))
check.call('oversize -> 552', '552', send_mail(relay, body: "#{'x' * 998}\r\n" * 300))
check.call('healthz', '200', Net::HTTP.get_response(URI("http://#{relay}:9090/healthz")).code)
metrics = Net::HTTP.get(URI("http://#{relay}:9090/metrics"))
check.call('metrics sent=1', true, metrics.include?('smtp_relay_messages_total{result="sent"} 1'))
check.call('metrics ses_retryable=2', true, metrics.include?('smtp_relay_messages_total{result="ses_retryable"} 2'))

exit(failures.empty? ? 0 : 1)
