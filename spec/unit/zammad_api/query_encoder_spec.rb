# frozen_string_literal: true

# What is asserted here is the order the pairs of a query are written in,
# because that order is all a query string has to say where one element of a
# list ends. Rack, and the parser Rails 8.1 has of its own, fill the element
# they are on until a pair names a place in it that is already taken, and
# begin a new one there. The orders below were read back with both, from the
# Zammad this gem is developed against, and came out as written.
RSpec.describe ZammadAPI::QueryEncoder do
  def written(query) = URI.decode_www_form(described_class.encode(ZammadAPI::Transport.stringify_query(query)))

  def faraday(query) = Faraday::NestedParamsEncoder.encode(ZammadAPI::Transport.stringify_query(query))

  let(:by_group) { { name: 'ticket.group_id', operator: 'is', value: [1] } }
  let(:by_title) { { name: 'ticket.title', operator: 'contains', value: 'x' } }

  describe '.encode' do
    # Everything but a list of Hashes that differ is written as it was.
    {
      'plain values'                  => { query: 'smith', page: 2, expand: true },
      'a list of plain values'        => { ids: [3, 1, 2] },
      'a Hash of lists'               => { group_ids: { 3 => %w[read change], 4 => 'full' } },
      'a condition keyed by name'     => { condition: { 'ticket.state_id' => { operator: 'is', value: [1, 2] } } },
      'a list of Hashes alike'        => { condition: { operator: 'AND', conditions: [{ name: 'a', operator: 'is', value: [1] }, { name: 'b', operator: 'is', value: [2] }] } },
      'a list with nothing in it'     => { ids: [] },
      'a value that needs escaping'   => { query: 'a b&c=d[e]' },
      'a list of Hashes of Hashes'    => { list: [{ a: { x: 1 } }, { a: { x: 2 } }] },
      'plain values among the Hashes' => { list: [1, { a: 1 }, 2, { b: 3 }] }
    }.each do |name, query|
      it "writes #{name} as Faraday does" do
        expect(described_class.encode(ZammadAPI::Transport.stringify_query(query))).to eq(faraday(query))
      end
    end

    # A condition and a group of conditions share `operator` and nothing
    # else. Written `conditions` first, the group was read into the condition
    # before it, and what was left of it began an element holding nothing but
    # its operator.
    it 'begins a group of conditions with the key it shares with the condition before it' do
      condition = { operator: 'OR', conditions: [{ name: 'ticket.state_id', operator: 'is', value: [2] }, { operator: 'AND', conditions: [by_group, by_title] }] }

      expect(written(condition: condition)).to eq(
        [
          ['condition[conditions][][name]', 'ticket.state_id'],
          ['condition[conditions][][operator]', 'is'],
          ['condition[conditions][][value][]', '2'],
          ['condition[conditions][][operator]', 'AND'],
          ['condition[conditions][][conditions][][name]', 'ticket.group_id'],
          ['condition[conditions][][conditions][][operator]', 'is'],
          ['condition[conditions][][conditions][][value][]', '1'],
          ['condition[conditions][][conditions][][name]', 'ticket.title'],
          ['condition[conditions][][conditions][][operator]', 'contains'],
          ['condition[conditions][][conditions][][value]', 'x'],
          ['condition[operator]', 'OR']
        ]
      )
    end

    # The other way round: `name` sorts first, and the group before has none.
    it 'begins a condition with the key it shares with the group before it' do
      condition = { operator: 'OR', conditions: [{ operator: 'AND', conditions: [by_group] }, { name: 'ticket.state_id', operator: 'is', value: [2] }] }

      expect(written(condition: condition).last(4)).to eq(
        [
          ['condition[conditions][][operator]', 'is'],
          ['condition[conditions][][name]', 'ticket.state_id'],
          ['condition[conditions][][value][]', '2'],
          ['condition[operator]', 'OR']
        ]
      )
    end

    it 'begins every group in a row of them with its operator' do
      condition = { conditions: [{ operator: 'OR', conditions: [by_group] }, { operator: 'NOT', conditions: [by_title] }, { operator: 'AND', conditions: [by_group] }] }

      expect(written(condition: condition).map(&:first).each_cons(2).count { |before, pair| pair == 'condition[conditions][][operator]' && before != pair })
        .to eq(2)
    end

    # The shared place may be further down, and every key on the way to it
    # goes first.
    it 'begins an element with a value it shares further down' do
      list = [{ a: { x: 1, y: { z: 1 } }, b: [1] }, { a: { w: [2], y: { q: 3, z: 2 } }, c: 4 }]

      expect(written(list: list).drop(3)).to eq([['list[][a][y][z]', '2'], ['list[][a][y][q]', '3'], ['list[][a][w][]', '2'], ['list[][c]', '4']])
    end

    it 'writes nothing for no query' do
      expect(described_class.encode(nil)).to be_nil
    end

    it 'writes an empty string for a query with nothing in it' do
      expect(described_class.encode({})).to eq('')
    end
  end

  describe '.decode' do
    it 'reads a query string the way Faraday does' do
      expect(described_class.decode('a[]=1&a[]=2&b[c]=3')).to eq('a' => %w[1 2], 'b' => { 'c' => '3' })
    end
  end

  describe '.lead_path' do
    it 'is the first key both have that holds a plain value' do
      expect(described_class.lead_path({ 'conditions' => [], 'operator' => 'AND' }, { 'name' => 'a', 'operator' => 'is' })).to eq(['operator'])
    end

    it 'is not needed after something that is not a Hash' do
      expect(described_class.lead_path({ 'a' => '1' }, 'x')).to be_nil
    end

    it 'does not go through a list' do
      expect(described_class.lead_path({ 'a' => ['1'] }, { 'a' => ['2'] })).to be_nil
    end

    it 'goes through a Hash to a place the element before has too' do
      expect(described_class.lead_path({ 'a' => { 'x' => '1' } }, { 'a' => { 'x' => '2' } })).to eq(%w[a x])
    end

    it 'does not go through a Hash where the element before holds a plain value' do
      expect(described_class.lead_path({ 'a' => { 'x' => '1' } }, { 'a' => '2' })).to be_nil
    end

    it 'is nil where the two share no key' do
      expect(described_class.lead_path({ 'a' => '1' }, { 'b' => '2' })).to be_nil
    end

    # Nothing is written for an empty Hash, so Rails never saw the key in the
    # element before, and a pair naming it is read into that element.
    it 'does not take a key the element before holds an empty Hash under' do
      expect(described_class.lead_path({ 'a' => '2', 'c' => '3' }, { 'a' => {}, 'b' => '1' })).to be_nil
    end

    it 'does not take one further down either' do
      expect(described_class.lead_path({ 'a' => { 'x' => '2' } }, { 'a' => { 'x' => {} } })).to be_nil
    end

    it 'takes another key the two share instead' do
      expect(described_class.lead_path({ 'a' => '2', 'b' => '3' }, { 'a' => {}, 'b' => '1' })).to eq(['b'])
    end
  end

  describe '.misread' do
    it 'is nil for a plain value' do
      expect(described_class.misread('x', { 'a' => '1' })).to be_nil
    end

    it 'is nil for the first Hash of a list' do
      expect(described_class.misread({ 'a' => ['1'] }, nil)).to be_nil
    end

    it 'is nil for a Hash after a plain value' do
      expect(described_class.misread({ 'a' => '1' }, 'x')).to be_nil
    end

    it 'is nil for a Hash that shares a plain value with the one before' do
      expect(described_class.misread({ 'operator' => 'AND', 'conditions' => [] }, { 'operator' => 'is', 'name' => 'a' })).to be_nil
    end

    it 'names a Hash that would be read into the one before' do
      expect(described_class.misread({ 'b' => '2' }, { 'a' => '1' })).to eq(:merged)
    end

    it 'names a Hash nothing is written for' do
      expect(described_class.misread({}, nil)).to eq(:empty)
    end

    it 'names a Hash holding nothing but such Hashes' do
      expect(described_class.misread({ 'a' => { 'b' => {} } }, nil)).to eq(:empty)
    end

    it 'names a Hash whose only shared key holds an empty Hash in the element before' do
      expect(described_class.misread({ 'a' => '2', 'c' => '3' }, { 'a' => {}, 'b' => '1' })).to eq(:merged)
    end

    it 'names a list directly inside a list' do
      expect(described_class.misread(%w[1 2], nil)).to eq(:list)
    end
  end
end
