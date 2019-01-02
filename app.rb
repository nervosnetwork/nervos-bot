require 'json'
require 'sinatra'
require 'openssl'

require_relative 'github_bot'

require 'dotenv/load'
github_app_id = ENV.fetch('GITHUB_APP_ID')
github_secret = ENV.fetch('GITHUB_SECRET', '')
github_private_pem = File.read(ENV.fetch('GITHUB_PRIVATE_PEM'))
github_private_key = OpenSSL::PKey::RSA.new(github_private_pem)

github_bot = GithubBot.new(
  app_id: github_app_id,
  secret: github_secret,
  private_key: github_private_key
)

if ENV['LOG_LEVEL'] then
  log_level = ENV['LOG_LEVEL'].to_i
  before do
    logger.level = log_level
  end
end

post '/github' do
  request.body.rewind
  payload_text = request.body.read

  if github_secret != '' then
    signature = 'sha1=' + OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha1'), github_secret, payload_text)
    unless Rack::Utils.secure_compare(signature, request.env.fetch('HTTP_X_HUB_SIGNATURE', '')) then
      return halt 500, "Signatures didn't match!" 
    end
  end

  payload = JSON.parse(payload_text)
  github_bot.on_request(payload, logger)

  ''
end
