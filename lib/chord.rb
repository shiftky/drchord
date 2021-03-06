#!/usr/bin/env ruby
# encoding: utf-8

drchord_dir = File.expand_path(File.dirname(__FILE__))
require  File.expand_path(File.join(drchord_dir, '/node_info.rb'))
require  File.expand_path(File.join(drchord_dir, '/utils.rb'))
require 'observer'
require 'drb/drb'
require 'logger'

module DRChord
  # Chord アルゴリズムに基づいた P2P ネットワークの構築・ルーティングを行う
  class Chord
    include Observable

    attr_reader :logger, :info, :finger, :successor_list, :predecessor
    def initialize(options, logger = nil)
      @logger = logger || Logger.new(STDERR)

      @info = NodeInformation.new(options[:ip], options[:port])

      @finger = []
      @successor_list = []
      @predecessor = nil

      @next = 0
      @active = false
      @in_ring = false
    end

    # ノードの ID を返す
    # @return [Fixnum] ノードの IP:Port から計算したハッシュ値
    def id
      return @info.id
    end

    # ノードが動作しているか状態を返す
    # @return [boolean]
    def active?
      return @active
    end

    # successor ノードの情報 (finger[0]) を返す
    # @return [NodeInfomation] successor ノードの情報を表す NodeInfomation クラスのインスタンス
    def successor
      return @finger[0]
    end

    # successor ノードの情報 (finger[0]) を変更する
    # @param [NodeInfomation] node successor ノードの情報を表す NodeInfomation クラスのインスタンス
    def successor=(node)
      @finger[0] = node
      logger.debug "set successor = #{@finger[0].uri}"
    end

    # predecessor ノードの情報を変更する
    # @param [NodeInfomation] node predecessor ノードの情報を表す NodeInfomation クラスのインスタンス
    def predecessor=(node)
      @predecessor = node
      logger.debug "set predecessor = #{node.nil? ? "nil" : node.uri}"
    end

    # 指定した ID の successor ノードを探す
    # @param [Fixnum] id 対象となる ID
    # @return [NodeInfomation] ID の successor ノードの情報を表す NodeInformation クラスのインスタンス
    def find_successor(id)
      if Utils.betweenE(id, self.id, self.successor.id)
        return self.successor
      else
        n1 = self.closest_preceding_finger(id)
        node = DRbObject::new_with_uri(n1.uri)
        return node.find_successor(id)
      end
    end

    # 指定した ID の predecessor ノードを探す
    # @param [Fixnum] id 対象となる ID
    # @return [NodeInfomation] ID の predecessor ノードの情報を表す NodeInformation クラスのインスタンス
    def find_predecessor(id)
      return @predecessor if id == self.id

      n1 = DRbObject::new_with_uri(@info.uri)
      while Utils.betweenE(id, n1.id, n1.successor.id) == false
        n1_info= n1.closest_preceding_finger(id)
        n1 = DRbObject::new_with_uri(n1_info.uri)
      end
      return n1.info
    end

    # ID 空間上でノード ID と指定した ID の範囲に位置するノード情報を finger table から探す
    # @param [Fixnum] id 対象となる ID
    # @return [NodeInfomation] NodeInformation クラスのインスタンス
    def closest_preceding_finger(id)
      (DRChord::HASH_BIT-1).downto(0) do |i|
        if Utils.between(@finger[i].id, self.id, id)
          return @finger[i] if alive?(@finger[i].uri)
        end
      end
      return @info
    end

    # 引数で与えられたノードが新しい predecessor である場合更新する
    # @param [NodeInformation] n 新たな predecessor 候補
    def notify(n)
      if @predecessor == nil || Utils.between(n.id, @predecessor.id, self.id)
        self.predecessor = n

        # 加入時委譲処理の要求
        if @in_ring == false
          @in_ring = true
          changed
          notify_observers
          logger.debug("Join network complete.")
        end
      end
    end

    # Chord ノードの動作を開始する
    # @param [String] bootstrap_node 既にネットワークに参加しているノードの URI
    def start(bootstrap_node)
      join(bootstrap_node)
      @chord_thread = Thread.new do
        loop do
          if active? == true
            stabilize
            fix_fingers
            fix_successor_list
            fix_predecessor
          end
          sleep DRChord::STABILIZE_INTERVAL
        end
      end
    end

    # Chord ネットワークに参加する
    # @param [String] bootstrap_node 既にネットワークに参加しているノードの URI
    def join(bootstrap_node = nil)
      if bootstrap_node.nil?
        self.predecessor = nil
        self.successor = @info
      else
        self.predecessor = nil
        begin
          node = DRbObject::new_with_uri(bootstrap_node)
          self.successor = node.find_successor(self.id)
        rescue DRb::DRbConnError => ex
          logger.error "Connection failed - #{node.__drburi}"
          logger.error ex.message
          exit
        end
      end
      build_finger_table(bootstrap_node)
      build_successor_list(bootstrap_node)
      @active = true
    end

    # Chord ネットワークから離脱する
    def leave
      logger.info "Node #{@info.uri} leaving..."
      @chord_thread.kill
      if self.successor != @predecessor
        begin
          DRbObject::new_with_uri(self.successor.uri).notify_predecessor_leaving(@info, @predecessor)
          DRbObject::new_with_uri(@predecessor.uri).notify_successor_leaving(@info, @successor_list) if @predecessor != nil
        rescue DRb::DRbConnError
        end
      end
      @active = false
    end

    # ノードの successor に predecessor が離脱することを通知する
    # @param [NodeInfomation] node 離脱するノードの情報（自ノード）
    # @param [NodeInfomation] new_predecessor 新たな predecessor となるノードの情報（自ノードの predecessor）
    def notify_predecessor_leaving(node, new_predecessor)
      if node == @predecessor
        self.predecessor = new_predecessor
      end
    end

    # ノードの predecessor に successor が離脱することを通知する
    # @param [NodeInformation] node 離脱するノードの情報（自ノード）
    # @param [Array <NodeInformation>] successors 新たな successor_list となるリスト（自ノードの successor_list）
    def notify_successor_leaving(node, successors)
      if node == self.successor
        @successor_list.delete_at(0)
        @successor_list << successors.last
        self.successor = @successor_list.first
      end
    end

    # id の successor 候補のリストを作成する
    # @param [Fixnum] id 対象となる ID
    # @param [Fixnum] max_number リストの最大サイズ
    # @return [Array <NodeInformation>] successor 候補の格納された Array
    def successor_candidates(id, max_number)
      begin
        successor_node = DRbObject::new_with_uri(find_successor(id).uri)
        list = [successor_node.info]
        list += successor_node.successor_list
      rescue DRb::DRbConnError
        begin
          predecessor_node = DRbObject::new_with_uri(find_predecessor(id).uri)
          list = predecessor_node.successor_list
        rescue DRb::DRbConnError
          return false
        end
      end

      while list.count < max_number
        begin
          last = DRbObject::new_with_uri(list.last.uri)
          list << last.successor
        rescue DRb::DRbConnError
          break
        end
      end
      return list[0..max_number-1]
    end

    # ネットワーク上のノードが自ノードのみであるかを確かめる
    # @return [Boolean] 自ノードのみである場合 true, そうでない場合 false
    def is_alone?
      unless @predecessor.nil?
        if @predecessor.id == self.id && self.successor.id == self.id
          return true
        end
      end
      return false
    end

    private
    def alive?(uri)
      begin
        node = DRbObject::new_with_uri(uri)
        return node.active?
      rescue DRb::DRbConnError
        return false
      end
    end

    def finger_start(k)
      return (self.id + 2**k) % 2**DRChord::HASH_BIT
    end

    def build_successor_list(bootstrap_node)
      @successor_list = [@finger[0]]
      while @successor_list.count < DRChord::SLIST_SIZE
        if bootstrap_node.nil?
          @successor_list << @info
        else
          begin
            last_node = DRbObject::new_with_uri(@successor_list.last.uri)
            @successor_list << last_node.successor
          rescue
            stabilize
            return
          end
        end
      end
    end

    def build_finger_table(bootstrap_node)
      if bootstrap_node.nil?
        return (DRChord::HASH_BIT-1).times { @finger << @info }
      else
        node = DRbObject::new_with_uri(bootstrap_node)
        0.upto(DRChord::HASH_BIT-2) do |i|
          if Utils.Ebetween(finger_start(i+1), self.id,  @finger[i].id)
            @finger[i+1] = @finger[i]
          else
            begin
              @finger[i+1] = node.find_successor(finger_start(i+1))
            rescue DRb::DRbConnError => ex
              logger.error "Connection failed - #{node.__drburi}"
              logger.error ex.message
              exit
            end
          end
        end
      end
    end

    def stabilize
      return if active? == false
      check_current_successor
      get_predecessor_of_the_successor
    end

    def check_current_successor
      if self.successor != nil && alive?(self.successor.uri) == false
        logger.debug "Stabilize: Successor node failure has occurred."

        @successor_list.delete_at(0)
        if @successor_list.count == 0
          (DRChord::HASH_BIT-1).downto(0) do |i|
            if alive?(@finger[i].uri) == true
              self.successor = @finger[i]
              stabilize
              return
            end
          end

          # There is nothing we can do, its over.
          @active = @in_ring = false
          return
        else
          self.successor = @successor_list.first
          stabilize
          return
        end
      end
    end

    def get_predecessor_of_the_successor
      begin
        succ_node = DRbObject::new_with_uri(self.successor.uri)
        x = succ_node.predecessor
      rescue DRb::DRbConnError
        return
      end

      if x != nil && alive?(x.uri)
        if Utils.between(x.id, self.id, self.successor.id)
          self.successor = x
        end
      end
      succ_node.notify(@info)
    end

    def fix_fingers
      @next += 1
      @next = 0 if @next >= DRChord::HASH_BIT
      @finger[@next] = find_successor(finger_start(@next))
    end

    def fix_successor_list
      begin
        list = DRbObject::new_with_uri(self.successor.uri).successor_list
        list.unshift(self.successor)
        @successor_list = list[0..DRChord::SLIST_SIZE-1]
      rescue DRb::DRbConnError
        return
      end
    end

    def fix_predecessor
      if @predecessor != nil && alive?(@predecessor.uri) == false
        self.predecessor = nil
      end
    end
  end
end
