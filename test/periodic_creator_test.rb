# frozen_string_literal: true

module Ginseng
  class PeriodicCreatorTest < TestCase
    # ⚠ 対応していないプラットフォームでは destroot が ImplementError を上げる。
    # 「動かせない」ので飛ばす（落とすのではなく）。
    SUPPORTED_PLATFORMS = [:freebsd, :darwin, :debian].freeze

    def disable?
      return true if environment_class.win?
      return true unless SUPPORTED_PLATFORMS.include?(environment_class.platform)
      return false
    end

    def setup
      return if disable?
      @creator = PeriodicCreator.new('weekly')
    end

    # ⚠⚠ **ディレクトリの存在を要求しない (#508)。** `/etc/cron.frequently` は
    # FreeBSD 由来の周期で、⚠ **Debian にも CI のコンテナにも無い**。存在は
    # デプロイ先の前提であってこのクラスの性質ではないので、**組み立てた
    # パスそのもの**を見る。
    def test_destroot
      PeriodicCreator.periods.each do |period|
        destroot = PeriodicCreator.destroot(period)

        assert_true(File.absolute_path?(destroot), "#{period}: 絶対パスであること")
        assert_include(destroot, period, "#{period}: 周期の名前が入ること")
      end
    end

    def test_destroot_rejects_unknown_period
      assert_raise(ArgumentError) do
        PeriodicCreator.destroot('yearly')
      end
    end

    # ⚠ **命名はプラットフォームで違う。** FreeBSD / macOS は連番付き、Debian は
    # 連番を持たず `_` を `-` へ寄せる。**走っているホストの形**を見る
    # （どちらか一方をベタ書きすると、もう一方で必ず落ちる）。
    def test_create_link_name
      name = PeriodicCreator.create_link_name(900, 'sample_task')

      assert_equal(expected_link_name, name)
    end

    def expected_link_name
      case environment_class.platform
      when :freebsd, :darwin
        return "900.#{environment_class.name}-sample_task"
      when :debian
        return "#{environment_class.name}-sample-task"
      end
    end

    def test_dir
      assert_equal(PeriodicCreator.destroot('weekly'), @creator.dir)
    end

    def test_counter
      assert_equal(900, @creator.counter)
    end
  end
end
