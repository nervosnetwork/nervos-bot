class GithubBot
  def initialize(opts)
    @app_id = opts.fetch(:app_id)
    @secret = opts.fetch(:secret)
    @private_key = opts.fetch(:private_key)
  end

  def logger
    @logger
  end

  def on_request(data, logger)
    if logger.debug?
      logger.debug("[github push] #{data}")
    end
  end
end
