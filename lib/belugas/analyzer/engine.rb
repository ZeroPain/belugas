require "securerandom"

module Belugas
  module Analyzer
    class Engine
      EngineFailure = Class.new(StandardError)
      EngineTimeout = Class.new(StandardError)

      attr_reader :name

      DEFAULT_MEMORY_LIMIT = 512_000_000.freeze

      def initialize(name, metadata, code_path, config, label, run_rules)
        @name = name
        @metadata = metadata
        @code_path = code_path
        @config = config
        @run_rules = run_rules
        @label = label.to_s
      end

      def run(results_io, container_listener)
        composite_listener = CompositeContainerListener.new(
          container_listener,
          LoggingContainerListener.new(qualified_name, Analyzer.logger),
          StatsdContainerListener.new(qualified_name.tr(":", "."), Analyzer.statsd),
          RaisingContainerListener.new(qualified_name, EngineFailure, EngineTimeout),
        )

        container = Container.new(
          image: @metadata["image"],
          command: @metadata["command"],
          name: container_name,
          listener: composite_listener,
        )

        # Although the final belugas output is buffered completely due to detected features needing
        # a post-processing during each stage, we will still need the engines to stream their output
        # and us to capture the output in parallel, as we might launch other engines in parallel
        # whenever we detect that the requirements for each engine is met:
        container.on_output("\0") do |raw_output|
          CLI.debug("#{qualified_name} engine output: #{raw_output.strip}")
          output = EngineOutput.new(raw_output)

          unless output.valid?
            results_io.failed("#{qualified_name} produced invalid output: #{output.error[:message]}")
            container.stop
          end

          unless output_filter.filter?(output)
            results_io.write(output) || container.stop
          end
        end

        write_config_file
        write_input_detected_features_file

        CLI.debug("#{qualified_name} engine config: #{config_file.read}")
        container.run(container_options).tap do |result|
          CLI.debug("#{qualified_name} engine stderr: #{result.stderr}")
        end
      rescue Container::ImageRequired
        # Provide a clearer message given the context we have
        message = "Unable to find an image for #{qualified_name}."
        message << " Available channels: #{@metadata["channels"].keys.inspect}."
        raise Container::ImageRequired, message
      ensure
        delete_config_file
        delete_input_detected_features_file
      end

      def input_detected_features_file
        @input_detected_features_file ||= MountedPath.tmp.join(SecureRandom.uuid)
      end

      def can_run?(partially_detected_features)
        return true unless @run_rules.present?

        dependency_engines_were_run?(partially_detected_features) &&
        dependency_features_were_found?(partially_detected_features)
      end

      private

      def dependency_engines_were_run?(partially_detected_features)
        run_dependencies_met? :engines, :engines, partially_detected_features
      end

      def dependency_features_were_found?(partially_detected_features)
        run_dependencies_met? :features, :name, partially_detected_features
      end

      def run_dependencies_met?(rule_key, feature_key, partially_detected_features)
        dependencies_to_meet = @run_rules.fetch(rule_key.to_s, []).sort
        dependencies_found = partially_detected_features.map(&feature_key).flatten.uniq
        (dependencies_to_meet & dependencies_found).sort == dependencies_to_meet
      end

      def qualified_name
        "#{name}:#{@config.fetch("channel", "stable")}"
      end

      def container_options
        [
          "--cap-drop", "all",
          "--label", "com.codeclimate.label=#{@label}",
          "--memory", memory_limit,
          "--memory-swap", "-1",
          "--net", "none",
          "--rm",
          "--volume", "#{@code_path}:/code:ro",
          "--volume", "#{config_file.host_path}:/config.json:ro",
          "--volume", "#{input_detected_features_file.host_path}:/previous-engine-results.json:ro",
          "--user", "9000:9000"
        ]
      end

      def container_name
        @container_name ||= "fd-engines-#{qualified_name.tr(":", "-")}-#{SecureRandom.uuid}"
      end

      def write_config_file
        config_file.write(@config.to_json)
      end

      def delete_config_file
        config_file.delete if config_file.file?
      end

      def config_file
        @config_file ||= MountedPath.tmp.join(SecureRandom.uuid)
      end

      def write_input_detected_features_file
        input_detected_features_file.write([].to_json)
      end

      def delete_input_detected_features_file
        input_detected_features_file if input_detected_features_file.file?
      end

      def output_filter
        @output_filter ||= EngineOutputFilter.new(@config)
      end

      # Memory limit for a running engine in bytes
      def memory_limit
        (ENV["ENGINE_MEMORY_LIMIT_BYTES"] || DEFAULT_MEMORY_LIMIT).to_s
      end
    end
  end
end
