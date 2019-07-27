require 'sinatra'
require 'octokit'
require 'dotenv/load'
require 'json'
require 'logger'

require_relative 'github_bot'
require_relative 'github_bot_brain'
require_relative 'alert_manager'

class GithubBotApp < Sinatra::Application
  WEBHOOK_SECRET = ENV['GITHUB_WEBHOOK_SECRET']
  BRAIN = GithubBotBrain.new

  configure :development do
    set :logging, Logger::DEBUG

    stack = Faraday::RackBuilder.new do |builder|
      builder.use Faraday::Request::Retry, exceptions: [Octokit::ServerError]
      builder.use Octokit::Middleware::FollowRedirects
      builder.use Octokit::Response::RaiseError
      builder.use Octokit::Response::FeedParser
      builder.response :logger
      builder.adapter Faraday.default_adapter
    end
    Octokit.middleware = stack
  end


  before '/github' do
    get_payload_request(request)
    verify_webhook_signature
    authenticate_app
    authenticate_installation(@payload)
  end


  post '/github' do
    @github_bot.on_event(request.env['HTTP_X_GITHUB_EVENT'], @payload)

    200
  end

  post '/alert-manager' do
    get_payload_request(request)

    @alert_manager = AlertManager.new
    @alert_manager.on_event(@payload)
  end


  helpers do
    # Saves the raw payload and converts the payload to JSON format
    def get_payload_request(request)
      # request.body is an IO or StringIO object
      # Rewind in case someone already read it
      request.body.rewind
      # The raw text of the body is required for webhook signature verification
      @payload_raw = request.body.read
      begin
        @payload = JSON.parse @payload_raw
      rescue => e
        fail  "Invalid JSON (#{e}): #{@payload_raw}"
      end
    end

    def authenticate_app
      @github_bot = GithubBot.new(BRAIN, logger: logger)
    end

    # Instantiate an Octokit client, authenticated as an installation of a
    # GitHub App, to run API operations.
    def authenticate_installation(payload)
      @github_bot.authenticate_installation(payload['installation']['id'])
    end

    def verify_webhook_signature
      their_signature_header = request.env['HTTP_X_HUB_SIGNATURE'] || 'sha1='
      method, their_digest = their_signature_header.split('=')
      our_digest = OpenSSL::HMAC.hexdigest(method, WEBHOOK_SECRET, @payload_raw)
      halt 401 unless their_digest == our_digest

      # The X-GITHUB-EVENT header provides the name of the event.
      # The action value indicates the which action triggered the event.
      logger.debug "---- received event #{request.env['HTTP_X_GITHUB_EVENT']}"
      logger.debug "----    action #{@payload['action']}" unless @payload['action'].nil?
    end

  end
end
