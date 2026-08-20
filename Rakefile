# frozen_string_literal: true

dir = File.expand_path(__dir__)
$LOAD_PATH.unshift(File.join(dir, 'lib'))
ENV['BUNDLE_GEMFILE'] = File.join(dir, 'Gemfile')

require 'ginseng'

# ⚠ cert タスクは gem が配る側（lib/tasks/cert.rake）に置いた (#512)。
# **この Rakefile も利用アプリと同じ入り口を通る**ので、配ったものが壊れていれば
# 自分の CI（rake cert:check）が先に落ちる。
Ginseng.load_tasks

namespace :bundle do
  desc 'update gems'
  task :update do
    sh 'bundle update'
  end

  desc 'install bundler'
  task :install_bundler do
    sh 'gem install bundler'
  end

  desc 'check gems'
  task check: [:install_bundler] do
    unless Ginseng::Environment.gem_fresh?
      warn 'gems is not fresh.'
      exit 1
    end
  end
end

desc 'test all'
task :test do
  Ginseng::TestCase.load((ARGV.first&.split(/[^[:word:],]+/) || [])[1])
end
