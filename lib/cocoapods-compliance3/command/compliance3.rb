require 'cocoapods'
require 'xcodeproj'
require 'cocoapods-compliance3/gem_version.rb'

module Pod
  class Command
    class Compliance < Command
      self.summary = 'Create CycloneDX json from Cocoapods and Swift Package Manager project dependencies.'

      self.description = <<-DESC
      A plugin designed to scan third-party dependencies from both Cocoapods and Swift Package Manager 
      in Xcode projects. This plugin generates a dependency report in the CycloneDX 1.4 JSON format with
      options to configure the output format.
      DESC

      def self.options
        [
          ['-n, --name=COMPONENT', 'The component name used in CycloneDX metadata'],
          ['-v, --version=VERSION', 'The component version used in CycloneDX metadata'],
          ['-f, --filename=FILENAME', 'The output filename (default is tp_bom.json)'],
          ['-t, --target=TARGET', 'The Xcode target to collect compliance information for'],
          ['-x, --xcodeproj=PATH', 'The path to the Xcode project'],
          ['-d, --download=PATH', 'Download the source code of the dependencies to PATH'],
          ['-p, --purl', 'One of default, platform, github, generic'],
          ['-u, --urlparameter', 'The source download url parameter appended to PURL (default is download_url)'],
          ['-a, --always', 'Always append source download URL to PURL (default is false)'],
        ].concat(super)
      end

      def initialize(argv)
        @componentName = argv.option('name') || argv.option('n')
        @componentVersion = argv.option('version') || argv.option('v')
        @filename = argv.option('filename') || argv.option('f') || 'tp_bom.json'
        @target = argv.option('target') || argv.option('t')
        @xcodeproj = argv.option('xcodeproj') || argv.option('x')
        @download_path = argv.option('download') || argv.option('d')
        @purlType = argv.option('purl') || argv.option('p') || 'default'
        @sourceParameter = argv.option('urlparameter') || argv.option('u') || 'download_url'
        @alwaysParameter = argv.flag?('always', false)

        @download_path = nil unless @download_path && !@download_path.empty?
        @target = nil unless @target && !@target.empty?

        @download_path = File.expand_path(@download_path) if @download_path        
        @filename = File.expand_path(@filename)

        @verbose = config.verbose?
        super
      end

      def validate!
        super
        help! 'Filename is required' unless @filename
        help! 'Component name is required. Use --name or -n.' unless @componentName
        help! 'Component version is required. Use --version or -v' if @componentVersion&.strip == ''
      end

      def run
        podfile_lock = config.lockfile
        podfile = Pod::Podfile.from_file(config.podfile_path)
        xcodeproj = @xcodeproj || Dir.glob('*.xcodeproj').first

        target_definition = nil
        if !@target.nil?
          target_definition = podfile.target_definition_list.select { |td| td.name == @target }&.first
        end
        if target_definition.nil?
          target_definition = podfile.target_definition_list.select { |td| td.name != "Pods" }&.first          
        end

        if target_definition&.user_project_path
          xcodeproj = target_definition&.user_project_path
        end

        UI.puts "Podfile: #{config.podfile_path}"
        UI.puts "Podfile.lock: #{config.lockfile_path}"
        UI.puts "Xcode project: #{xcodeproj}"
        UI.puts "Target: #{target_definition.name}" if target_definition
        UI.puts "Download path: #{@download_path}" if @download_path
      
        swift_dependencies = extract_swift_package_references(xcodeproj);
        pod_dependencies = extract_podfile_lock_dependencies(podfile, podfile_lock, target_definition);

        components = (swift_dependencies + pod_dependencies)
        compliance_info = to_cyclon_dx(@componentName, @componentVersion, components)
        
        FileUtils.mkdir_p(@download_path) if @download_path
        FileUtils.mkdir_p(File.dirname(@filename)) if @filename
        File.write(@filename, JSON.pretty_generate(compliance_info))

        if @download_path
          FileUtils.mkdir_p(@download_path)
          download(swift_dependencies + pod_dependencies)
        end

        UI.puts "Compliance information saved to #{@filename}"
      end

      def extract_podfile_lock_dependencies(podfile, podfile_lock, target_definition)
        dependencies = podfile.dependencies
        unless target_definition.nil?
          dependencies = target_definition.dependencies.select do |dependency|
            r = target_definition.pod_whitelisted_for_configuration?(dependency.name, 'Release')
            UI.puts "Skipping #{dependency.name} as it is not configured for 'Release'" if !r
            r
          end
        end
        
        dependencies.map do |pod|
          UI.puts "Collecting compliance information for #{pod.name}" if @verbose

          checkout_options = podfile_lock.checkout_options_for_pod_named(pod.name) || {}

          sources_manager = Pod::Config.instance.sources_manager
          spec_set = sources_manager.search(pod)

          if spec_set.nil?
            UI.warn "Np spec_set found for #{pod.name}"
            next
          end

          spec = spec_set.specification
          version = spec.version&.to_s
          commit = checkout_options[:commit]
          tag = spec.source[:tag]

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
            commit: commit,
            platform: 'cocoapods'
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
          UI.puts JSON.pretty_generate(obj.package.requirement) if @verbose

          version = obj.package.requirement['version']
          commit = obj.package.requirement['revision'] || obj.package.requirement['branch']
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
            commit: commit,
            platform: 'spm'
          }
        end
      end

      def to_cyclon_dx(name, version, components)
        c = components.map { |info| to_cyclon_dx_component(info) }
        {
          bomFormat: 'CycloneDX',
          serialNumber: "urn:uuid:#{SecureRandom.uuid}",
          version: '1',
          specVersion: '1.4',
          metadata: {
            timestamp: Time.now.utc.iso8601,
            component: {
              name: name,
              version: version
            },
            tools: [
              {
                name: 'cocoapods-compliance3',
                version: CocoapodsCompliance3::VERSION
              },
            ] 
          },
          components: c
        }
      end

      def to_cyclon_dx_component(info)
        pkg_url = nil
        
        # todo: https://github.com/package-url/purl-spec/blob/master/PURL-TYPES.rst#cocoapods
        # Should cocoapods be supported for purl?        
        # When you enter the “purl”, if the project is hosted on GitHub, use “pkg:github/XXX/YYY@GIT_TAG” which 
        # provides a canonical way to download the source for compliance scanning.

        if @purlType == 'platform'
          if info[:platform] == 'cocoapods'
            pkg_url = purl_cocoapods(info)
          elsif info[:platform] == 'spm'
            pkg_url = purl_swift(info)
          end
        elsif @purlType == 'github'
          pkg_url = purl_github(info)
        elsif @purlType == 'generic'
          pkg_url = purl_generic(info)
        end 

        unless pkg_url
          if info[:commit]
            pkg_url = purl_generic(info)
          else
            pkg_url = purl_github(info)
          end
        end

        if @alwaysParameter || pkg_url&.include?("generic/")
          pkg_url = append_download_url_to_purl(pkg_url, info)
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

      def purl_github(info)
        return nil unless info[:website]&.include?('github.com')
        version = info[:tag] || info[:version] || ''
        owner, repo = info[:website].chomp('.git').chomp('/').split('/')[-2..-1]  
        "pkg:github/#{owner}/#{repo}@#{version}"
      end

      def purl_generic(info)
        v = info[:commit] || info[:tag] || info[:version] || ''
        "pkg:generic/swift/#{info[:name]}@#{v}"
      end

      def purl_cocoapods(info)
        v = info[:version] || ''
        "pkg:cocoapods/#{info[:name]}@#{v}"
      end

      def purl_swift(info)
        return nil unless info[:website]
        host, owner, repo = info[:website].chomp('.git').chomp('/').split('/')[-3..-1]  
        v = info[:version] || ''
        "pkg:swift/#{host}/#{owner}/#{repo}@#{v}"
      end

      def append_download_url_to_purl(purl, info) 
        return unless info[:download_url]
        url_encoded = URI.encode_www_form_component(info[:download_url]) if info[:download_url]
        download = info[:download_url] && url_encoded ? "?#{@sourceParameter}=#{url_encoded}" : ''
        purl + download
      end

      def download(dependencies)
        dependencies.each do |info|
          if (info[:name].nil? && info[:version].nil?) || info[:download_url].nil?
            UI.warn "Skipping download as it is missing name, version or download_url"
            UI.warn info
            next
          end

          UI.puts "Downloading #{info[:name]} from #{info[:download_url]}" if @verbose
          archive_name = File.basename(info[:name])
          download_path = File.join(@download_path, "#{archive_name}-#{info[:version]}.tar.gz")
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
