require 'cocoapods'
require 'xcodeproj'
require 'cocoapods-compliance3/gem_version.rb'

module Pod
  class Command
    class Compliance < Command
      self.summary = 'Short description of cocoapods-compliance3.'

      self.description = <<-DESC
        Longer description of cocoapods-compliance3.
      DESC

      def self.options
        [
          ['--component=COMPONENT', 'The component to collect compliance information for.'],
          ['--version=VERSION', 'The version of the component to collect compliance information for.'],
          ['--target=TARGET', 'The target to collect compliance information for.'],
          ['--xcodeproj=PATH', 'The path to the Xcode project.'],
          ['--output=PATH', 'The path to save the compliance information.'],
          ['--filename=FILENAME', 'The filename of the compliance information. Default is compliance.json.'],
          ['--download', 'Download the source code of the dependencies.'],
          ['--generic', 'Use generic package URL for CycloneDX BOM, also for GitHub repositories.']
        ].concat(super)
      end

      def initialize(argv)
        @output_path = File.expand_path(argv.option('output') || Dir.pwd)
        @filename = argv.option('filename') || 'compliance.json'
        @download = argv.flag?('download', false)
        @target = argv.option('target')
        @xcodeproj = argv.option('xcodeproj')
        @genericPkgUrls = argv.flag?('generic', false)
        @componentName = argv.option('component')
        @componentVersion = argv.option('version')
        super
      end

      def validate!
        super
        help! 'Output path is required' unless @output_path
        help! 'Filename is required' unless @filename
        help! 'Component name is required' unless @componentName
        help! 'Component version is required' if @componentVersion&.strip == ''
      end

      def run
        @verbose = config.verbose?
        podfile_lock = config.lockfile
        podfile = Pod::Podfile.from_file(config.podfile_path)
        xcodeproj = @xcodeproj || Dir.glob('*.xcodeproj').first
        target_definition = nil

        unless @target.nil?
          target_definition = podfile.target_definition_list.select { |td| td.name == @target }.first
        else 
          target_definition = podfile.target_definition_list.select { |td| td.name != "Pods" }.first
        end

        user_project_path = target_definition.user_project_path
        xcodeproj = user_project_path if user_project_path

        UI.puts "Using Xcode project: #{xcodeproj}" if @verbose
        UI.puts "Using target: #{target_definition.name}" if target_definition && @verbose
      
        swift_dependencies = extract_swift_package_references(xcodeproj);
        pod_dependencies = extract_podfile_lock_dependencies(podfile, podfile_lock, target_definition);

        components = (swift_dependencies + pod_dependencies).map do |info|
          to_cyclon_dx_component(info)
        end

        compliance_info = {
          bomFormat: 'CycloneDX',
          serialNumber: "urn:uuid:#{SecureRandom.uuid}",
          version: '1',
          specVersion: '1.4',
          metadata: {
            timestamp: Time.now.utc.iso8601,
            component: {
              name: @componentName,
              version: @componentVersion
            },
            tools: [
              {
                vendor: 'Cumulocity IoT',
                name: 'cocoapods-compliance3',
                version: CocoapodsCompliance3::VERSION
              },
            ] 
          },
          components: components
        }
        # create output directory if it does not exist
        FileUtils.mkdir_p(@output_path) unless File.directory?(@output_path)

        File.write(File.join(@output_path, @filename), JSON.pretty_generate(compliance_info))

        if @download
          download(swift_dependencies + pod_dependencies)
        end

        UI.puts "Compliance information saved to #{@output_path}"
      end

      def extract_podfile_lock_dependencies(podfile, podfile_lock, target_definition)
        dependencies = []
        unless target_definition.nil?
          dependencies = target_definition.dependencies.select do |dependency|
            r = target_definition.pod_whitelisted_for_configuration?(dependency.name, 'Release')
            UI.puts "Skipping #{dependency.name} as it is not configured for 'Release'" if !r
            r
          end
        else 
          dependencies = podfile.dependencies
        end

        dependencies.map do |pod|
          UI.puts "Collecting compliance information for #{pod.name}" if @verbose

          checkout_options = podfile_lock.checkout_options_for_pod_named(pod.name) || {}

          sources_manager = Pod::Config.instance.sources_manager
          spec_set = sources_manager.search(pod)

          if spec_set.nil?
            UI.warn "Specification for #{pod.name} not found"
            next
          end

          spec = spec_set.specification
          version = spec.version&.to_s
          commit = checkout_options[:commit]
          tag = spec.source[:tag]

          UI.puts "Version: #{version}, Tag: #{tag}, Commit: #{commit}"

          base_url = spec.source[:git] || spec.source[:http]
          download_base_url = base_url.chomp('.git').chomp('/')
          download_url = "#{download_base_url}/archive/#{commit || tag || version}.tar.gz"

          {
            type: 'library',
            name: pod.name,
            requires: pod.requirement.to_s,
            license: spec.license[:type],
            authors: spec.authors,
            summary: spec.summary,
            description: spec.description,
            website: spec.homepage,
            download_url: download_url,
            version: version,
            tag: tag,
            commit: commit
          }
        end
      end

      def extract_swift_package_references(project_path)
        project = Xcodeproj::Project.open(project_path)

        project.objects.filter_map do |obj|
          next unless obj.isa == 'XCSwiftPackageProductDependency'
          next unless obj.package.isa == 'XCRemoteSwiftPackageReference'

          name = obj.product_name
          UI.puts "Collecting compliance information for #{name}" if @verbose

          version = obj.package.requirement['version']
          commit = obj.package.requirement['revision']
          website = obj.package.repositoryURL.chomp('.git').chomp('/')
          download_url = "#{website}/archive/#{commit || version}.tar.gz"

          license = nil
          description = nil

          if website.include?('github.com')
            repo_info = fetch_github_repo_metadata(website)
            next if repo_info.nil?
            license = repo_info['license']['spdx_id'] if repo_info['license']
            description = repo_info['description']
          end

          {
            name: name,
            version: version,
            type: 'library',
            download_url: download_url,
            license: license,
            description: description,
            website: website,
            commit: commit
          }
        end
      end

      def to_cyclon_dx_component(info)
        pkg_url = nil
        
        # todo: https://github.com/package-url/purl-spec/blob/master/PURL-TYPES.rst#cocoapods
        # Should cocoapods be supported for purl?
        
        # When you enter the “purl”, if the project is hosted on GitHub, use “pkg:github/XXX/YYY@GIT_TAG” which 
        # provides a canonical way to download the source for compliance scanning.
        version = info[:tag] || info[:version]
        commit = info[:commit]

        # UI.puts "#{info}" 

        if !commit && !version.nil? && !version.strip.empty? && info[:website]&.include?('github.com') && !@genericPkgUrls
          UI.puts "website: #{info[:website]}" if @verbose
          owner, repo = info[:website].chomp('.git').chomp('/').split('/')[-2..-1]  
          pkg_url = "pkg:github/#{owner}/#{repo}@#{version}"
        end

        # fallback to generic package URL
        unless pkg_url
          url_encoded = URI.encode_www_form_component(info[:download_url]) if info[:download_url]
          v = info[:commit] || info[:tag] || info[:version]
          if v && info[:download_url] && url_encoded
            pkg_url = "pkg:generic/cocoapods/#{info[:name]}@#{v}?download_url=#{url_encoded}"
          end
        end
        
        component = {
          type: info[:type],
          name: info[:name],
          version: info[:version],
          purl: pkg_url
        }

        description = info[:summary] || info[:description]
        component["author"] = info[:authors].map { |a| "#{a[0]} <#{a[1]}>" }.join(', ') if info[:authors]
        component["description"] = description if description
        component["licenses"] = [{ license: { id: info[:license] } }] if info[:license]

        component
      end

      def download(dependencies)
        dependencies.each do |info|
          if info[:name].nil? || info[:version].nil? || info[:download_url].nil?
            UI.warn "Skipping download as it is missing name, version or download_url"
            UI.warn info
            next
          end

          UI.puts "Downloading #{info[:name]} from #{info[:download_url]}" if @verbose
          archive_name = File.basename(info[:name])
          download_path = File.join(@output_path, "#{archive_name}-#{info[:version]}.tar.gz")
          URI.parse(info[:download_url]).open do |download|
            File.write(download_path, download.read)
          end
        end
      end

      def fetch_github_repo_metadata(website)
        github_api_url = website.gsub('github.com', 'api.github.com/repos')
        UI.puts "Fetching meta information from  #{github_api_url}" if @verbose

        uri = URI.parse(github_api_url)
        response = Net::HTTP.get_response(uri)

        if response.is_a?(Net::HTTPSuccess)
          metadata = JSON.parse(response.body)
          return metadata
        else
          UI.warn "Error downloading repository infos: #{response.message}"
          return nil
        end
      end
    end
  end
end
