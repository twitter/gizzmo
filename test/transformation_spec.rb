require File.expand_path('../spec_helper', __FILE__)

describe Gizzard::Transformation do
  Op = Gizzard::Transformation::Op

  def create_shard(t);      Op::CreateShard.new(mk_template(t)) end
  def delete_shard(t);      Op::DeleteShard.new(mk_template(t)) end
  def add_link(f, t);       Op::AddLink.new(mk_template(f), mk_template(t)) end
  def remove_link(f, t);    Op::RemoveLink.new(mk_template(f), mk_template(t)) end
  def copy_shard(f, t);     Op::CopyShard.new(mk_template(f), mk_template(t)) end
  def set_forwarding(t);    Op::SetForwarding.new(mk_template(t)) end
  def remove_forwarding(t); Op::RemoveForwarding.new(mk_template(t)) end
  def commit_begin(t);      Op::CommitBegin.new(mk_template(t)) end
  def commit_end(t);        Op::CommitEnd.new(mk_template(t)) end

  def empty_ops
    Hash[[:prepare, :copy, :cleanup, :repair, :diff, :unblock_writes, :unblock_reads].map {|key| [key, []]}]
  end

  before do
    @nameserver = stub!.subject
    stub(@nameserver).dryrun? { false }

    @config = Gizzard::MigratorConfig.new :prefix => "status", :table_id => 0

    @from_template = mk_template 'ReplicatingShard -> (BlockedShard -> SqlShard(host1), SqlShard(host2))'
    @to_template   = mk_template 'ReplicatingShard -> (SqlShard(host2), SqlShard(host3))'

    @blocked_template = mk_template 'BlockedShard -> SqlShard(host1)'
    @host_1_template  = mk_template 'SqlShard(host1)'
    @host_2_template  = mk_template 'SqlShard(host2)'
    @host_3_template  = mk_template 'SqlShard(host3)'

    @trans = Gizzard::Transformation.new(@from_template, @to_template)
  end

  describe "initialization" do
    it "allows an optional copy wrapper type" do
      Gizzard::Transformation.new(@from_template, @to_template)
      Gizzard::Transformation.new(@from_template, @to_template, 'WriteOnlyShard')
      Gizzard::Transformation.new(@from_template, @to_template, 'BlockedShard')
      lambda do
        Gizzard::Transformation.new(@from_template, @to_template, 'InvalidWrapperShard')
      end.should raise_error(ArgumentError)
    end
  end

  describe "eql?" do
    it "is true for two transformation involving equivalent templates" do
      templates = lambda { ["SqlShard(host1)", "SqlShard(host2)"].map {|s| mk_template s } }
      Gizzard::Transformation.new(*templates.call).should.eql? Gizzard::Transformation.new(*templates.call)
      Gizzard::Transformation.new(*templates.call).hash.should.eql? Gizzard::Transformation.new(*templates.call).hash
    end
  end

  # internal method tests

  describe "operations" do
    it "does a basic replica addition" do
      from = mk_template 'ReplicatingShard -> (SqlShard(host1), SqlShard(host2))'
      to   = mk_template 'ReplicatingShard -> (SqlShard(host1), SqlShard(host2), SqlShard(host3))'

      Gizzard::Transformation.new(from, to, 'BlockedShard').operations.should == empty_ops.merge({
        :prepare => [ create_shard('SqlShard(host3)'),
                      create_shard('BlockedShard'),
                      add_link('BlockedShard', 'SqlShard(host3)'),
                      add_link('ReplicatingShard', 'BlockedShard') ],
        :copy =>    [ copy_shard('SqlShard(host1)', 'SqlShard(host3)') ],
        :cleanup => [ add_link('ReplicatingShard', 'SqlShard(host3)'),
                      commit_begin('ReplicatingShard'),
                      remove_link('ReplicatingShard', 'BlockedShard'),
                      remove_link('BlockedShard', 'SqlShard(host3)'),
                      delete_shard('BlockedShard'),
                      commit_end('ReplicatingShard') ]
      })
    end

    describe "does a partition migration" do
      from = mk_template 'ReplicatingShard -> (SqlShard(host1), SqlShard(host2))'
      to   = mk_template 'ReplicatingShard -> (SqlShard(host3), SqlShard(host4))'

      it "in standard mode" do
        Gizzard::Transformation.new(from, to).operations.should == empty_ops.merge({
          :prepare => [ create_shard('SqlShard(host4)'),
                        create_shard('WriteOnlyShard'),
                        create_shard('WriteOnlyShard'),
                        create_shard('SqlShard(host3)'),
                        add_link('ReplicatingShard', 'WriteOnlyShard'),
                        add_link('WriteOnlyShard', 'SqlShard(host4)'),
                        add_link('WriteOnlyShard', 'SqlShard(host3)'),
                        add_link('ReplicatingShard', 'WriteOnlyShard') ],
          :copy =>    [ copy_shard('SqlShard(host1)', 'SqlShard(host4)'),
                        copy_shard('SqlShard(host1)', 'SqlShard(host3)') ],
          :cleanup => [ add_link('ReplicatingShard', 'SqlShard(host4)'),
                        add_link('ReplicatingShard', 'SqlShard(host3)'),
                        commit_begin('ReplicatingShard'),
                        remove_link('ReplicatingShard', 'WriteOnlyShard'),
                        remove_link('ReplicatingShard', 'WriteOnlyShard'),
                        remove_link('WriteOnlyShard', 'SqlShard(host3)'),
                        remove_link('ReplicatingShard', 'SqlShard(host1)'),
                        remove_link('ReplicatingShard', 'SqlShard(host2)'),
                        remove_link('WriteOnlyShard', 'SqlShard(host4)'),
                        delete_shard('SqlShard(host1)'),
                        delete_shard('SqlShard(host2)'),
                        delete_shard('WriteOnlyShard'),
                        delete_shard('WriteOnlyShard'),
                        commit_end('ReplicatingShard') ]
        })
      end

      it "in batch mode" do
        batch_finish = true
        Gizzard::Transformation.new(from, to, nil, false, batch_finish).operations.should == empty_ops.merge({
          :unblock_writes =>
                      [ create_shard('WriteOnlyShard'),
                        create_shard('WriteOnlyShard'),
                        add_link('ReplicatingShard', 'WriteOnlyShard'),
                        add_link('WriteOnlyShard', 'SqlShard(host3)'),
                        add_link('WriteOnlyShard', 'SqlShard(host4)'),
                        add_link('ReplicatingShard', 'WriteOnlyShard'),
                        remove_link('ReplicatingShard', 'BlockedShard'),
                        remove_link('BlockedShard', 'SqlShard(host3)'),
                        remove_link('BlockedShard', 'SqlShard(host4)'),
                        remove_link('ReplicatingShard', 'BlockedShard'),
                        delete_shard('BlockedShard'),
                        delete_shard('BlockedShard')],
          :unblock_reads =>
                      [ add_link('ReplicatingShard', 'SqlShard(host3)'),
                        add_link('ReplicatingShard', 'SqlShard(host4)'),
                        remove_link('ReplicatingShard', 'WriteOnlyShard'),
                        remove_link('WriteOnlyShard', 'SqlShard(host3)'),
                        remove_link('WriteOnlyShard', 'SqlShard(host4)'),
                        remove_link('ReplicatingShard', 'WriteOnlyShard'),
                        delete_shard('WriteOnlyShard'),
                        delete_shard('WriteOnlyShard')],
          :prepare => [ create_shard('SqlShard(host4)'),
                        create_shard('BlockedShard'),
                        create_shard('BlockedShard'),
                        create_shard('SqlShard(host3)'),
                        add_link('ReplicatingShard', 'BlockedShard'),
                        add_link('BlockedShard', 'SqlShard(host4)'),
                        add_link('BlockedShard', 'SqlShard(host3)'),
                        add_link('ReplicatingShard', 'BlockedShard') ],
          :cleanup => [ commit_begin('ReplicatingShard'),
                        remove_link('ReplicatingShard', 'SqlShard(host2)'),
                        remove_link('ReplicatingShard', 'SqlShard(host1)'),
                        delete_shard('SqlShard(host2)'),
                        delete_shard('SqlShard(host1)'),
                        commit_end('ReplicatingShard') ],
          :copy =>    [ copy_shard('SqlShard(host2)', 'SqlShard(host4)'),
                        copy_shard('SqlShard(host2)', 'SqlShard(host3)') ]
        })
      end
    end

    describe "rebalances a tree containing a write-only shard" do
      to = mk_template 'ReplicatingShard -> (SqlShard(host3), WriteOnlyShard -> SqlShard(host4))'
      children = [
        Gizzard::Shard.new(info("host1", "tbl_001_a", "SqlShard"), [], 1),
        Gizzard::Shard.new(
          info("localhost", "tbl_001_write_only", "WriteOnlyShard"),
          [Gizzard::Shard.new(info("host2", "tbl_001_b", "SqlShard"), [], 1)],
          1)
      ]
      trees = {
        forwarding(0, 0, id("localhost", "tbl_001_rep")) =>
          Gizzard::Shard.new(info("localhost", "tbl_001_rep", "ReplicatingShard", "", "", 0), children, 1)
      }
      dest_templates_and_weights = { to => 1 }
      copy_wrapper = "BlockedShard"

      it "without batch finish" do
        batch_finish = false

        rebalancer = Gizzard::Rebalancer.new(trees, dest_templates_and_weights, copy_wrapper, batch_finish)
        rebalancer.transformations.size.should == 1
        transformation = rebalancer.transformations.clone.shift[0]
        transformation.operations.should == empty_ops.merge({
          :prepare => [ create_shard('SqlShard(host4)'),
                        create_shard('BlockedShard'),
                        create_shard('BlockedShard'),
                        create_shard('SqlShard(host3)'),
                        create_shard('WriteOnlyShard'),
                        add_link('ReplicatingShard', 'WriteOnlyShard'),
                        add_link('WriteOnlyShard', 'BlockedShard'),
                        add_link('BlockedShard', 'SqlShard(host4)'),
                        add_link('BlockedShard', 'SqlShard(host3)'),
                        add_link('ReplicatingShard', 'BlockedShard') ],
          :copy =>    [ copy_shard('SqlShard(host1)', 'SqlShard(host4)'),
                        copy_shard('SqlShard(host1)', 'SqlShard(host3)') ],
          :cleanup => [ add_link('WriteOnlyShard', 'SqlShard(host4)'),
                        add_link('ReplicatingShard', 'SqlShard(host3)'),
                        commit_begin('ReplicatingShard'),
                        remove_link('ReplicatingShard', 'SqlShard(host1)'),
                        remove_link('BlockedShard', 'SqlShard(host3)'),
                        remove_link('ReplicatingShard', 'WriteOnlyShard'),
                        remove_link('WriteOnlyShard', 'BlockedShard'),
                        remove_link('BlockedShard', 'SqlShard(host4)'),
                        remove_link('WriteOnlyShard', 'SqlShard(host2)'),
                        remove_link('ReplicatingShard', 'BlockedShard'),
                        delete_shard('SqlShard(host1)'),
                        delete_shard('WriteOnlyShard'),
                        delete_shard('BlockedShard'),
                        delete_shard('SqlShard(host2)'),
                        delete_shard('BlockedShard'),
                        commit_end('ReplicatingShard') ]
        })
      end

      it "with batch finish" do
        batch_finish = true
        rebalancer = Gizzard::Rebalancer.new(trees, dest_templates_and_weights, copy_wrapper, batch_finish)
        rebalancer.transformations.size.should == 1
        transformation = rebalancer.transformations.clone.shift[0]
        transformation.operations.should == empty_ops.merge({
          :prepare =>
            [create_shard("BlockedShard"),
            create_shard("SqlShard(host3)"),
            create_shard("BlockedShard"),
            create_shard("SqlShard(host4)"),
            create_shard("WriteOnlyShard"),
            add_link("ReplicatingShard", "BlockedShard"),
            add_link("BlockedShard", "SqlShard(host3)"),
            add_link("WriteOnlyShard", "BlockedShard"),
            add_link("BlockedShard", "SqlShard(host4)"),
            add_link("ReplicatingShard", "WriteOnlyShard")],
          :copy =>
            [copy_shard("SqlShard(host1)", "SqlShard(host3)"),
            copy_shard("SqlShard(host1)", "SqlShard(host4)")],
          :unblock_writes =>
            [create_shard("WriteOnlyShard"),
            create_shard("WriteOnlyShard"),
            add_link("WriteOnlyShard", "SqlShard(host3)"),
            add_link("ReplicatingShard", "WriteOnlyShard"),
            add_link("WriteOnlyShard", "SqlShard(host4)"),
            add_link("WriteOnlyShard", "WriteOnlyShard"),
            remove_link("ReplicatingShard", "BlockedShard"),
            remove_link("BlockedShard", "SqlShard(host3)"),
            remove_link("WriteOnlyShard", "BlockedShard"),
            remove_link("BlockedShard", "SqlShard(host4)"),
            delete_shard("BlockedShard"),
            delete_shard("BlockedShard")],
          :unblock_reads =>
            [add_link("ReplicatingShard", "SqlShard(host3)"),
            add_link("WriteOnlyShard", "SqlShard(host4)"),
            remove_link("WriteOnlyShard", "SqlShard(host3)"),
            remove_link("ReplicatingShard", "WriteOnlyShard"),
            remove_link("WriteOnlyShard", "SqlShard(host4)"),
            remove_link("WriteOnlyShard", "WriteOnlyShard"),
            delete_shard("WriteOnlyShard"),
            delete_shard("WriteOnlyShard")],
          :cleanup =>
            [commit_begin("ReplicatingShard"),
            remove_link("ReplicatingShard", "SqlShard(host1)"),
            remove_link("WriteOnlyShard", "SqlShard(host2)"),
            remove_link("ReplicatingShard", "WriteOnlyShard"),
            delete_shard("SqlShard(host1)"),
            delete_shard("SqlShard(host2)"),
            delete_shard("WriteOnlyShard"),
            commit_end("ReplicatingShard")]
        })
      end
    end

    it "migrates the top level shard" do
      from = mk_template 'ReplicatingShard -> (SqlShard(host1), SqlShard(host2))'
      to   = mk_template 'FailingOverShard -> (SqlShard(host1), SqlShard(host2))'

      Gizzard::Transformation.new(from, to).operations.should == empty_ops.merge({
        :prepare => [ create_shard('FailingOverShard'),
                      add_link('FailingOverShard', 'SqlShard(host2)'),
                      add_link('FailingOverShard', 'SqlShard(host1)'),
                      set_forwarding('FailingOverShard'),
                      commit_begin('ReplicatingShard'),
                      remove_forwarding('ReplicatingShard'),
                      remove_link('ReplicatingShard', 'SqlShard(host1)'),
                      remove_link('ReplicatingShard', 'SqlShard(host2)'),
                      delete_shard('ReplicatingShard'),
                      commit_end('ReplicatingShard') ]
      })
    end

    it "wraps a shard" do
      from = mk_template 'ReplicatingShard -> (SqlShard(host1), SqlShard(host2))'
      to   = mk_template 'ReplicatingShard -> (ReadOnlyShard -> SqlShard(host1), SqlShard(host2))'

      Gizzard::Transformation.new(from, to).operations.should == empty_ops.merge({
        :prepare => [ create_shard('ReadOnlyShard'),
                      add_link('ReadOnlyShard', 'SqlShard(host1)'),
                      add_link('ReplicatingShard', 'ReadOnlyShard'),
                      commit_begin('ReplicatingShard'),
                      remove_link('ReplicatingShard', 'SqlShard(host1)'),
                      commit_end('ReplicatingShard') ]
      })
    end

    it "raises an argument error if the transformation requires a copy without a valid source" do
      to = mk_template 'ReplicatingShard -> (SqlShard(host1), SqlShard(host2))'

      fulfill = lambda {|type| if type == "BlackHoleShard"; "#{type}(hostz)"; else type end}

      Gizzard::Shard::INVALID_COPY_TYPES.each do |invalid_type|
        fulfilled = fulfill.call(invalid_type)
        from = mk_template "ReplicatingShard -> #{fulfilled} -> SqlShard(host1)"
        lambda { Gizzard::Transformation.new(from, to) }.should raise_error(ArgumentError)
      end
    end
  end

  describe "collapse_jobs" do
    def collapse(jobs); @trans.collapse_jobs(jobs) end

    it "works" do
      jobs = [ Op::AddLink.new(@host_1_template, @host_2_template),
               Op::AddLink.new(@host_1_template, @host_3_template) ]
      collapse(jobs).should == jobs

      collapse([ Op::AddLink.new(@host_1_template, @host_2_template),
                 Op::RemoveLink.new(@host_1_template, @host_2_template) ]).should == []

      collapse([ Op::RemoveLink.new(@host_1_template, @host_2_template),
                 Op::AddLink.new(@host_1_template, @host_2_template) ]).should == []

      collapse(@trans.create_tree(@from_template) + @trans.destroy_tree(@from_template)).should == []

      collapse(@trans.create_tree(@to_template) + @trans.destroy_tree(@from_template)).sort!.should ==
        [ Op::CreateShard.new(@host_3_template),
          Op::AddLink.new(@to_template, @host_3_template),
          Op::CommitBegin.new(@to_template),
          Op::RemoveLink.new(@blocked_template, @host_1_template),
          Op::RemoveLink.new(@from_template, @blocked_template),
          Op::DeleteShard.new(@host_1_template),
          Op::DeleteShard.new(@blocked_template),
          Op::CommitEnd.new(@to_template) ]
    end
  end

  describe "copy_destination?" do
    it "returns true if the given template is not a member of the from_template" do
      @trans.copy_destination?(@host_3_template).should == true
    end

    it "returns false when there is no from_template (completely new shards, no data to copy)" do
      @trans = Gizzard::Transformation.new(nil, @to_template)
      @trans.copy_destination?(@host_1_template).should == false
      @trans.copy_destination?(@host_2_template).should == false
      @trans.copy_destination?(@host_3_template).should == false
    end

    it "returns false if the given template is a member of the from_template (therefore has source data)" do
      @trans.copy_destination?(@host_1_template).should == false
      @trans.copy_destination?(@host_2_template).should == false
    end

    it "returns false if the given template is not concrete" do
      @trans.copy_destination?(@to_template).should == false
    end
  end

  describe "in_copied_subtree?" do
    it "returns true for copy sources" do
      @trans.in_copied_subtree?(@host_2_template).should == true
    end

    it "returns true for members of a subtree that contains copy sources, but who are not copy sources" do
      @trans.in_copied_subtree?(@host_1_template).should == true
      @trans.in_copied_subtree?(@blocked_template).should == true
    end

    it "returns false for templates added in the destination" do
      @trans.in_copied_subtree?(@host_3_template).should == false
    end
  end
end
