#!/usr/bin/env ruby
# encoding: utf-8

drchord_dir = File.expand_path(File.dirname(__FILE__))
require File.expand_path(File.join(drchord_dir, '/chord.rb'))
require File.expand_path(File.join(drchord_dir, '/dhash.rb'))
require 'optparse'
require 'drb/drb'

module DRChord
  # dRuby サーバの公開を行い DRChord のサービスを提供する
  class Front
    attr_reader :options, :chord, :dhash
    def initialize(logger)
      @logger = logger || Logger.new(STDERR)
      @options = option_parser(default_options)

      @chord = Chord.new(@options, @logger)
      @dhash = DHash.new(@chord, @logger)

      @active = true
    end

    # ノードが動作しているか状態を返す
    # @return [Boolean]
    def active?
      return @active
    end

    # ノードの dRuby URI を返す
    # @return [String] ノードの Front への参照を表す URI
    def uri
      return "druby://#{@options[:ip]}:#{@options[:port]}"
    end

    # オプション付き URI を提供する
    # @param [String] args 要求するインスタンス
    # @return [DRbObject] オプションで指定したインスタンスの DRbObject
    def [](args)
      case args
      when "chord"; return @chord
      when "dhash"; return @dhash
      end
    end

    # dRuby サーバを立ち上げサービスの提供を開始する
    def start
      begin
        DRb.start_service(uri, self, :safe_level => 1)
        @logger.info "dRuby server start - #{uri}"
      rescue Errno::EADDRINUSE
        @logger.error "Address and port already in use. - #{uri}"; exit
      end
    end

    private
    # コマンドライン引数のパースを行う
    def option_parser(options)
      OptionParser.new do |opt|
        opt.banner = "Usage: ruby #{File.basename($0)} [options]"
        opt.on('-i --ip', 'ip address') {|v| options[:ip] = v }
        opt.on('-p --port', 'port') {|v| options[:port] = v.to_i }
        opt.on('-e --bootstrap_node', 'bootstrap node (existing node)  IP_ADDR:PORT') {|v| options[:bootstrap_node] = "druby://#{v}?chord" }
        opt.on_tail('-h', '--help', 'show this message') {|v| puts opt; exit }
        begin
          opt.parse!
        rescue OptionParser::InvalidOption
          puts "Error: Invalid option. \n#{opt}"; exit
        end
      end
      return options
    end

    # ノードのデフォルトオプションを返す
    def default_options
      return {:ip => '127.0.0.1', :port => 3000}
    end
  end
end
