require 'mongoriver'
require 'mongo'
require 'minitest/autorun'
require 'mocha/setup'
require_relative './cursor_stub'

def mocked_mongo()
  mongo_connection = stub()
  db = stub()
  collection = stub()

  mongo_connection.expects(:db).with('_mongoriver').returns(db)
  db.expects(:collection).with('oplog-tailers').returns(collection)

  # mongodb
  mongo_connection.expects(:server_info).at_least_once.returns({})

  [mongo_connection, collection]
end

describe 'Mongoriver::PersistentTailer' do
  before do
    @service_name = "_persistenttailer_test"

    @mongo_connection, @state_collection = mocked_mongo

    @tailer = Mongoriver::PersistentTailer.new(
      [@mongo_connection], :existing, @service_name)
    @state = {
      'time' => Time.now,
      'position' => 'foobar'
    }
  end

  describe 'reading and storing state' do
    it 'should be able to read the written state' do

      @state_collection.expects(:update)
      @tailer.save_state(@state)

      @state_collection.expects(:find_one).returns({
        'state' => @state,
        'v' => 1
      })
      assert_equal(@state, @tailer.read_state)
    end

    it 'should update gracefully' do
      ts = BSON::Timestamp.new(77, 0)

      @state_collection.expects(:find_one).returns('timestamp' => ts)
      @tailer.expects(:most_recent_position).with(Time.at(77))

      assert_equal(Time.at(77), @tailer.read_state['time'])
    end
  end

  it 'helper methods for timestamps/positions' do
    @state_collection.expects(:find_one).returns({
      'state' => @state,
      'v' => 1
    }).at_least_once

    assert_equal(@state['time'], @tailer.read_timestamp)
    assert_equal(@state['position'], @tailer.read_position)
  end

  it 'should tail from position' do
    @tailer.expects(:read_position).returns('foo')
    Mongoriver::Tailer.any_instance.expects(:tail).with(:from => 'foo')

    @tailer.tail
  end

  it 'should stream with state' do
    # Uses admin to verify that it is a replicaset
    admin_db = stub()
    admin_db.expects(:command).returns({'setName' => 'replica'})
    @mongo_connection.expects(:db).with('admin').returns(admin_db)
    # Updates state collection when finish iteration
    @state_collection.expects(:update)

    # Oplog collection to return results
    local_db = stub()
    @mongo_connection.expects(:db).with('local').returns(local_db)
    oplog_collection = stub()
    local_db.expects(:collection).with('oplog.rs').returns(oplog_collection)
    cursor = CursorStub.new
    oplog_collection.expects(:find).yields(cursor)

    @tailer.tail(:from => BSON::Timestamp.new(Time.now.to_i, 0))

    cursor.generate_ops(10)

    count = 0
    @tailer.stream do |record, state|
      count = state.count
      state.break 
    end
    assert_equal(1, count)
  end
end
