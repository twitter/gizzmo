module Gizzard
  Shard = Struct.new(:info, :children, :weight)

  class Shard
    class << self
      def canonical_table_prefix(enum, table_id = nil, base_prefix = "shard")
        enum_s         = "%0.4i" % enum
        table_id_s     = table_id.nil? ? nil : table_id < 0 ? "n#{table_id.abs}" : table_id.to_s
        [base_prefix, table_id_s, enum_s].compact.join('_')
      end

      def parse_enumeration(table_prefix)
        if match = table_prefix.match(/\d{3,}/)
          match[0].to_i
        else
          raise "Cannot derive enumeration!"
        end
      end
    end

    VIRTUAL_SHARD_TYPES = [
      "FailingOverShard",
      "ReplicatingShard",
      "ReadOnlyShard",
      "WriteOnlyShard",
      "BlockedShard",
    ]

    REPLICATING_SHARD_TYPES = ["ReplicatingShard", "FailingOverShard"]

    INVALID_COPY_TYPES = ["ReadOnlyShard", "WriteOnlyShard", "BlockedShard"]

    SHARD_SUFFIXES = {
      "FailingOverShard" => 'replicating',
      "ReplicatingShard" => 'replicating',
      "ReadOnlyShard" => 'read_only',
      "WriteOnlyShard" => 'write_only',
      "BlockedShard" => 'blocked'
    }

    def id; info.id end
    def hostname; id.hostname end
    def table_prefix; id.table_prefix end
    def class_name; info.class_name end
    def source_type; info.source_type end
    def destination_type; info.destination_type end
    def busy; info.busy end

    def template
      child_templates = children.map {|c| c.template }

      ShardTemplate.new(info.class_name,
                        id.hostname,
                        weight,
                        info.source_type,
                        info.destination_type,
                        child_templates)
    end

    def transformation(to)
      Transformation.new(template, to)
    end

    def enumeration
      self.class.parse_enumeration(table_prefix)
    end

    def canonical_shard_id_map(base_prefix = "shard", table_id = nil, enum = nil)
      enum         ||= self.enumeration
      base           = Shard.canonical_table_prefix(enum, table_id, base_prefix)
      suffix         = SHARD_SUFFIXES[class_name.split('.').last]
      canonical_name = [base, suffix].compact.join('_')
      canonical_id   = ShardId.new(self.hostname, canonical_name)

      children.inject(canonical_id => self.id) do |m, c|
        m.update c.canonical_shard_id_map(base_prefix, table_id, enum)
      end
    end
  end

  class Nameserver

    DEFAULT_PORT = 7917
    DEFAULT_RETRIES = 20
    PARALLELISM = 10

    attr_reader :hosts, :logfile, :dryrun
    alias dryrun? dryrun

    def initialize(*hosts)
      options = hosts.last.is_a?(Hash) ? hosts.pop : {}
      @retries = options[:retries] || DEFAULT_RETRIES
      @logfile = options[:log] || "/tmp/gizzmo.log"
      @dryrun = options[:dry_run] || false
      @hosts = hosts.flatten
    end

    def get_all_links(forwardings=nil)
      mutex         = Mutex.new
      all_links     = {}
      forwardings ||= client.get_forwardings
      forwardings   = forwardings.dup

      Thread.abort_on_exception = true

      threads = (0..(PARALLELISM - 1)).map do |i|
        Thread.new do
          done   = {}
          client = create_client(hosts.first)

          while f = mutex.synchronize { forwardings.pop }
            pending = [f.shard_id]

            until pending.empty?
              id = pending.pop

              unless done[id]
                links = with_retry { client.list_downward_links id }
                links.each {|l| pending << l.down_id }
                mutex.synchronize { links.each {|l| all_links[l] = true } }
                done[id] = true
              end
            end
          end
        end
      end

      threads.each {|t| t.join }

      all_links.keys
    end

    def get_all_shards
      client.list_hostnames.inject([]) do |a, hostname|
        a.concat client.shards_for_hostname(hostname)
      end
    end

    def get_shards(ids)
      ids.map {|id| with_retry { client.get_shard(id) } }
    end

    def reload_config
      all_clients.each {|c| with_retry { c.reload_config } }
    end

    def respond_to?(method)
      client.respond_to? method or super
    end

    def method_missing(method, *args, &block)
      client.respond_to?(method) ? with_retry { client.send(method, *args, &block) } : super
    end

    def manifest(filter = {})
      Manifest.new(self, filter)
    end

    private

    def client
      @client ||= create_client(hosts.first)
    end

    def all_clients
      @all_clients ||= hosts.map {|host| create_client(host) }
    end

    def create_client(host)
      host, port = host.split(":")
      port ||= DEFAULT_PORT
      Manager.new(host, port.to_i, logfile, dryrun)
    end

    private

    def with_retry
      times ||= @retries
      yield
    rescue ThriftClient::Simple::ThriftException, NoMethodError
      times -= 1
      (times < 0) ? raise : (sleep 2; retry)
    end

    class Manifest
      attr_reader :forwardings, :links, :shard_infos, :trees, :templates

      SUPPORTED_FILTERS = [:table_id, :forwardings]

      def initialize(nameserver, filter = {})
        unless (unsupported = filter.keys - SUPPORTED_FILTERS).empty?
          raise ArgumentError, "unsupported filter: #{unsupported.first.inspect}"
        end

        @forwardings = get_filtered_forwardings(nameserver, filter)

        @links = nameserver.get_all_links(forwardings).inject({}) do |h, link|
          (h[link.up_id] ||= []) << [link.down_id, link.weight]; h
        end

        infos =
          if filter[:forwardings]
            ids = @links.inject([]) {|a,(u,ds)| (a << u).concat ds.map {|d| d[0] } }
            nameserver.get_shards(ids)
          else
            nameserver.get_all_shards
          end

        @shard_infos = infos.inject({}) do |h, shard|
          h.update shard.id => shard
        end

        @trees = forwardings.inject({}) do |h, forwarding|
          h.update forwarding => build_tree(forwarding.shard_id)
        end

        @templates = @trees.inject({}) do |h, (forwarding, shard)|
          (h[shard.template] ||= []) << forwarding; h
        end
      end

      private

      def get_filtered_forwardings(nameserver, filter)
        return filter[:forwardings] if filter[:forwardings]

        forwardings = nameserver.get_forwardings

        if table_id = filter[:table_id]
          forwardings.reject! {|f| f.table_id != table_id }
        end

        forwardings
      end

      def build_tree(shard_id, link_weight=ShardTemplate::DEFAULT_WEIGHT)
        children = (links[shard_id] || []).map do |(child_id, child_weight)|
          build_tree(child_id, child_weight)
        end

        info = shard_infos[shard_id] or raise "shard info not found for: #{shard_id}"
        Shard.new(info, children, link_weight)
      end
    end
  end
end