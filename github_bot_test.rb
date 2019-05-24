# frozen_string_literal: true

require 'minitest/autorun'

require_relative 'github_bot'
require_relative 'github_bot_brain'

class GithubBotTest < Minitest::Test
  KEY = OpenSSL::PKey::RSA.generate(1024)
  attr_reader :bot

  def setup
    @tg = Minitest::Mock.new
    @brain = GithubBotBrain.new
    @bot = GithubBot.new(@brain, tg: @tg, private_key: KEY)
  end

  def repository(name)
    {
      'id' => 1,
      'name' => name
    }
  end

  def user(login)
    {
      'login' => login
    }
  end

  def test_assign_reviewer
    @brain.reviewers['ckb'] = %w(foo bar bot)
    client = Minitest::Mock.new
    client.expect :add_assignees, nil, [1, 9, ['foo']]
    client.expect :add_comment, nil, [1, 9, /@foo is assigned/]
    @bot.installation_client = client
    @bot.assign_reviewer(
      'repository' => repository('ckb'),
      'pull_request' => {
        'number' => 9,
        'user' => user('bot')
      }
    )

    assert_equal(@brain.reviewers['ckb'], %w(bar bot foo))
  end

  def test_assign_reviewer_when_next_is_self
    @brain.reviewers['ckb'] = %w(foo bar bot)
    client = Minitest::Mock.new
    client.expect :add_assignees, nil, [1, 9, ['bar']]
    client.expect :add_comment, nil, [1, 9, /@bar is assigned/]
    @bot.installation_client = client
    @bot.assign_reviewer(
      'repository' => repository('ckb'),
      'pull_request' => {
        'number' => 9,
        'user' => user('foo')
      }
    )

    assert_equal(@brain.reviewers['ckb'], %w(foo bot bar))
  end
end
