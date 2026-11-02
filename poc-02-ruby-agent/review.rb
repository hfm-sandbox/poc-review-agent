# frozen_string_literal: true

require 'json'
require 'digest'
require 'optparse'
require 'timeout'
require 'time'

module ReviewPoc
  ROOT = __dir__
  class InvalidReview < StandardError; end

  # Both adapters call the same in-memory tool. No repository discovery in PoC 2.
  class Source
    attr_reader :calls, :failed

    def initialize(fixture, fail: false)
      @fixture, @fail, @calls, @failed = fixture, fail, [], false
    end

    def read
      @calls << {name: 'read_source', arguments: {}}
      if @calls.size > 4 || @fail
        @failed = true
        raise IOError, 'read_source failed (PoC fault injection or call limit)'
      end
      {path: @fixture.fetch('path'), content: @fixture.fetch('source')}
    end
  end

  def self.validate!(review, source, fixture, schema)
    require 'json_schemer'
    raise InvalidReview, 'source tool failed; no review decision' if source.failed
    raise InvalidReview, 'read_source was not called' if source.calls.empty?
    raise InvalidReview, 'review does not conform to schema' unless JSONSchemer.schema(schema).valid?(review)

    review.fetch('findings').each do |finding|
      unless finding['path'] == fixture['path'] &&
             (1..fixture['source'].lines.size).cover?(finding['line']) &&
             !finding['body'].strip.empty?
        raise InvalidReview, 'finding has invalid location or empty body'
      end
    end
    review
  end

  def self.run_rubyllm(provider, model, source, prompt, instructions, schema, usage)
    require 'ruby_llm'
    RubyLLM.configure do |config|
      config.max_retries = 0
      config.request_timeout = 60
      if provider == 'anthropic'
        config.anthropic_api_key = ENV.fetch('ANTHROPIC_API_KEY')
      else
        require 'aws-sdk-bedrockruntime'
        aws = Aws::BedrockRuntime::Client.new(region: ENV.fetch('AWS_REGION'))
        config.bedrock_region = aws.config.region
        config.bedrock_credential_provider = aws.config.credentials
      end
    end

    # Named class keeps the model-facing tool name stable across adapters.
    unless const_defined?(:ReadSource, false)
      const_set(:ReadSource, Class.new(RubyLLM::Tool) do
        description 'Read the complete changed Ruby file.'
        attr_accessor :source
        def self.tool_name = 'read_source'
        def execute = source.read
      end)
    end
    tool = ReadSource.new
    tool.source = source
    chat = RubyLLM.chat(model: model, provider: provider.to_sym, assume_model_exists: true)
      .with_instructions(instructions)
      .with_max_output_tokens(2048)
      .with_tools(tool)
      .with_schema(schema)
    begin
      response = chat.ask(prompt)
      raise InvalidReview, "incomplete response: #{response.finish_reason}" unless response.finish_reason == :stop
      response.parsed
    ensure
      chat.messages.select { |m| m.role == :assistant }.each do |message|
        usage << {tokens: message.tokens.to_h, stop_reason: message.finish_reason}
      end
    end
  end

  def self.run_anthropic(provider, model, source, prompt, instructions, schema, usage)
    require 'anthropic'
    client = if provider == 'anthropic'
               Anthropic::Client.new(api_key: ENV.fetch('ANTHROPIC_API_KEY'), max_retries: 0, timeout: 60)
             else
               Anthropic::BedrockClient.new(aws_region: ENV.fetch('AWS_REGION'), max_retries: 0, timeout: 60)
             end
    messages = [{role: 'user', content: prompt}]
    tool = {name: 'read_source', description: 'Read the complete changed Ruby file.',
            input_schema: {type: 'object', properties: {}, additionalProperties: false}}
    # Explicit loop: measure the SDK's basic Messages API, without a separate agent runtime.
    8.times do
      response = client.messages.create(
        model: model, max_tokens: 2048, system_: instructions, messages: messages,
        tools: [tool], output_config: {format: {type: 'json_schema', schema: schema}}
      )
      usage << {tokens: response.usage.to_h, stop_reason: response.stop_reason}
      blocks = JSON.parse(response.to_json).fetch('content')
      messages << {role: 'assistant', content: blocks}
      calls = blocks.select { |block| block['type'] == 'tool_use' }
      if response.stop_reason.to_s == 'tool_use'
        raise InvalidReview, 'tool_use response without calls' if calls.empty?
        results = calls.map do |call|
          unless call['name'] == 'read_source' && call['input'] == {}
            raise InvalidReview, 'unexpected tool name or arguments'
          end
          {type: 'tool_result', tool_use_id: call.fetch('id'), content: JSON.generate(source.read)}
        end
        messages << {role: 'user', content: results}
      else
        unless response.stop_reason.to_s == 'end_turn' && calls.empty?
          raise InvalidReview, "incomplete response: #{response.stop_reason}"
        end
        return JSON.parse(blocks.select { |b| b['type'] == 'text' }.map { |b| b['text'] }.join)
      end
    end
    raise InvalidReview, 'model turn limit reached'
  end

  def self.main(argv)
    options = {adapter: 'rubyllm', provider: 'anthropic', case: 'bug', findings_event: 'COMMENT'}
    parser = OptionParser.new do |p|
      p.banner = 'bundle exec ruby review.rb --adapter rubyllm|anthropic --provider anthropic|bedrock --model MODEL'
      p.on('--adapter NAME', %w[rubyllm anthropic]) { |v| options[:adapter] = v }
      p.on('--provider NAME', %w[anthropic bedrock]) { |v| options[:provider] = v }
      p.on('--model ID') { |v| options[:model] = v }
      p.on('--case NAME', %w[bug clean]) { |v| options[:case] = v }
      p.on('--findings-event EVENT', %w[COMMENT REQUEST_CHANGES]) { |v| options[:findings_event] = v }
      p.on('--tool-error') { options[:tool_error] = true }
      p.on('-h', '--help') { puts p; return 0 }
    end
    parser.parse!(argv)
    raise ArgumentError, 'unexpected positional arguments' unless argv.empty?
    raise ArgumentError, '--model is required (use the same Claude version for comparison)' if options[:model].to_s.empty?

    fixture = JSON.parse(File.read(File.join(ROOT, 'fixtures.json'))).fetch(options[:case])
    schema = JSON.parse(File.read(File.join(ROOT, 'schema.json')))
    instructions = File.read(File.join(ROOT, 'instructions.txt'))
    # The expected answer is for humans only and is never sent to the model.
    prompt = "Review this diff. Use read_source to inspect #{fixture.fetch('path')}.\n\n#{fixture.fetch('diff')}"
    source = Source.new(fixture, fail: options[:tool_error])
    usage = []
    report = {status: 'error', adapter: options[:adapter], provider: options[:provider],
              model: options[:model], case: options[:case], tool_error: !!options[:tool_error],
              started_at: Time.now.utc.iso8601, ruby: RUBY_VERSION,
              input_sha256: Digest::SHA256.hexdigest(JSON.generate([instructions, prompt, schema, fixture['source']])),
              usage_by_turn: usage, tool_calls: source.calls}
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    begin
      review = Timeout.timeout(180) do
        public_send("run_#{options[:adapter]}", options[:provider], options[:model], source, prompt, instructions, schema, usage)
      end
      validate!(review, source, fixture, schema)
      report[:review] = review
      report[:event] = review.fetch('findings').empty? ? 'APPROVE' : options[:findings_event]
      # This is a smoke check, not an automated judge of finding quality.
      report[:expected_shape_matches] = if options[:case] == 'clean'
                                          review['findings'].empty?
                                        else
                                          review['findings'].any? { |f| f['path'] == 'average.rb' && f['line'] == 4 }
                                        end
      report[:status] = 'ok'
    rescue StandardError, LoadError => e
      message = e.message.to_s
      %w[ANTHROPIC_API_KEY AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_BEARER_TOKEN_BEDROCK].each do |name|
        value = ENV[name]
        message = message.gsub(value, '[REDACTED]') if value && !value.empty?
      end
      report[:error] = {class: e.class.name, message: message}
    ensure
      report[:elapsed_seconds] = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3)
      report[:token_totals] = %i[input_tokens output_tokens cache_read_tokens cache_write_tokens].to_h do |key|
        provider_key = {cache_read_tokens: :cache_read_input_tokens,
                        cache_write_tokens: :cache_creation_input_tokens}.fetch(key, key)
        values = usage.filter_map do |turn|
          counts = turn[:tokens]
          counts[key] || counts[provider_key]
        end
        [key, values.empty? ? nil : values.sum]
      end
      report[:gems] = Gem.loaded_specs.slice('ruby_llm', 'anthropic', 'aws-sdk-bedrockruntime', 'json_schemer')
        .transform_values { |spec| spec.version.to_s }
      puts JSON.pretty_generate(report)
    end
    report[:status] == 'ok' ? 0 : 1
  rescue OptionParser::ParseError, ArgumentError => e
    warn e.message
    warn parser
    2
  end
end

exit ReviewPoc.main(ARGV) if $PROGRAM_NAME == __FILE__
