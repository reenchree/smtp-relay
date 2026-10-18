# frozen_string_literal: true

# Minimal SES v2 SendEmail stand-in for the container smoke test.
#   POST /_mode/{ok,error,throttle}  switch behaviour
#   GET  /_last                       raw data of the last accepted message
require 'webrick'
require 'json'
require 'base64'

mode = 'ok'
last = ''
server = WEBrick::HTTPServer.new(BindAddress: '0.0.0.0', Port: Integer(ENV.fetch('PORT', 4566)),
                                 AccessLog: [], Logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN))

server.mount_proc('/_mode') do |req, res|
  mode = req.path.split('/').last
  res.body = mode
end
server.mount_proc('/_last') { |_req, res| res.body = last }

server.mount_proc('/v2/email/outbound-emails') do |req, res|
  res['Content-Type'] = 'application/json'
  case mode
  when 'ok'
    last = Base64.decode64(JSON.parse(req.body).dig('Content', 'Raw', 'Data'))
    res.body = JSON.generate(MessageId: "fake-#{Time.now.to_f}")
  when 'throttle'
    res.status = 429
    res['x-amzn-ErrorType'] = 'TooManyRequestsException'
    res.body = '{"message":"slow down"}'
  else
    res.status = 500
    res['x-amzn-ErrorType'] = 'InternalServiceErrorException'
    res.body = '{"message":"boom"}'
  end
end

trap('TERM') { server.shutdown }
server.start
