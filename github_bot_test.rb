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
    @bot.installation_client = Minitest::Mock.new
  end

  def repo(name, opts = {})
    {
      'id' => 1,
      'name' => name
    }.merge(opts)
  end

  def user(login)
    {
      'login' => login
    }
  end

  def test_assign_reviewer
    @brain.reviewers['ckb'] = %w[foo bar bot]
    @bot.installation_client.expect :add_assignees, nil, [1, 9, ['foo']]
    @bot.installation_client.expect :add_comment, nil, [1, 9, /@foo is assigned/]
    @bot.assign_reviewer(
      'repository' => repo('ckb'),
      'pull_request' => {
        'number' => 9,
        'user' => user('bot')
      }
    )

    assert_equal(@brain.reviewers['ckb'], %w[bar bot foo])
  end

  def test_assign_reviewer_when_next_is_self
    @brain.reviewers['ckb'] = %w[foo bar bot]
    @bot.installation_client.expect :add_assignees, nil, [1, 9, ['bar']]
    @bot.installation_client.expect :add_comment, nil, [1, 9, /@bar is assigned/]
    @bot.assign_reviewer(
      'repository' => repo('ckb'),
      'pull_request' => {
        'number' => 9,
        'user' => user('foo')
      }
    )

    assert_equal(@brain.reviewers['ckb'], %w[foo bot bar])
  end

  def test_ci_fork_sync_skip
    @brain.ci_fork_projects << 'ckb'
    @bot.ci_fork_sync(
      'repository' => repo('ckb1')
    )
    @bot.ci_fork_sync(
      'repository' => repo('ckb'),
      'pull_request' => {
        'head' => {
          'repo' => repo('ckb')
        },
        'base' => {
          'repo' => repo('ckb')
        }
      }
    )
  end

  def test_ci_fork_sync_delete_ref
    @brain.ci_fork_projects << 'ckb'
    @bot.installation_client.expect :delete_ref, nil, [1, 'heads/pr-mirror/123']
    @bot.ci_fork_sync(
      'action' => 'closed',
      'repository' => repo('ckb'),
      'pull_request' => {
        'number' => 123,
        'head' => {
          'repo' => repo('ckb')
        },
        'base' => {
          'repo' => repo('ckb', 'id' => 2)
        }
      }
    )
  end

  def test_ci_fork_sync_create_ref
    sha = 'ba2a58e951378979309ed0d0a7ec52a7f819d683'

    @brain.ci_fork_projects << 'ckb'
    @bot.installation_client.expect :create_ref, nil, [1, 'heads/pr-mirror/123', sha]
    @bot.ci_fork_sync(
      'action' => 'opened',
      'repository' => repo('ckb'),
      'pull_request' => {
        'number' => 123,
        'head' => {
          'repo' => repo('ckb'),
          'sha' => sha
        },
        'base' => {
          'repo' => repo('ckb', 'id' => 2)
        }
      }
    )
  end

  def test_ci_fork_sync_update_ref
    sha = 'ba2a58e951378979309ed0d0a7ec52a7f819d683'

    @brain.ci_fork_projects << 'ckb'
    @bot.installation_client.expect :create_ref, nil do
      raise Octokit::UnprocessableEntity.new(body: "Reference already exists")
    end
    @bot.installation_client.expect :update_ref, nil, [1, 'heads/pr-mirror/123', sha, true]
    @bot.ci_fork_sync(
      'action' => 'opened',
      'repository' => repo('ckb'),
      'pull_request' => {
        'number' => 123,
        'head' => {
          'repo' => repo('ckb'),
          'sha' => sha
        },
        'base' => {
          'repo' => repo('ckb', 'id' => 2)
        }
      }
    )
  end
end
