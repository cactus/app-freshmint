require 'ostruct'
require 'nokogiri'
require 'open-uri'
require 'versionomy'
require 'cfpropertylist'
require 'logger'
require 'stringio'
require 'ansi'

module Freshmint
    VERSION = '0.1'

    attr_writer :log

    # setup attr_reader manually, to provide a
    # default value and avoid internal errors
    def self.log
        if !defined? @log 
            @log = Logger.new(STDERR)
            @log.level = Logger::UNKNOWN
        end
        @log
    end

    def self.log=(log)
        @log = log
    end

    def self.find_apps(appdir)
        Dir[File.join(appdir, '*.app')]
    end

    def self.nice_version(ug='', ly='')
        # guard against nil values
        ug ||= ''
        ly ||= ''

        nice = ''
        if !ug.empty? and !ly.empty?
            nice = sprintf '%s-%s', ug, ly
        end
        if !ug.empty? and ly.empty?
            nice = ug
        end
        if !ly.empty? and ug.empty?
            nice = ly
        end
        nice
    end

    def self.read_plist(appdir)
        plist_path = File.join(appdir, 'Contents', 'Info.plist')
        return nil unless File.exists? plist_path
            
        plist = CFPropertyList::List.new(:file => plist_path)
        data = CFPropertyList.native_types(plist.value)
        return nil unless data.has_key? 'SUFeedURL'

        app = OpenStruct.new
        app.SUFeedURL = data['SUFeedURL']
        app.version_user = data['CFBundleShortVersionString']
        app.version = data['CFBundleVersion']
        app.plist_path = plist_path
        app.app_path = appdir
        app.executable = data['CFBundleExecutable']
        app.name = data['CFBundleName'] || app.executable
        if app.version_user and app.version != app.version_user
            app.version_nice = nice_version(app.version_user, app.version)
        else
            app.version_nice = app.version
        end
        log.debug "found #{app.name} => #{app.version_nice}"
        return app
    end

    def self.check_version_feed(app)
        return if app.nil?
        log.debug "fetching sparkle appcast data for #{app.name}"
        log.debug "fetching url => #{app.SUFeedURL}"
        #appcast = Nokogiri::XML(open(app.SUFeedURL))
        appcast = Nokogiri::XML(app.sparkle_data)
        releases = appcast.xpath(
            "//rss/channel/item/enclosure", 
            'sparkle' => "http://www.andymatuschak.org/xml-namespaces/sparkle")

        if releases.size == 0
            p app
            return nil
        end

        if releases.size > 1
            releases = releases.sort do |x,y| 
                # some version numbers aren't parseable by Versionomy,
                # such as propane.app's version string. resort to crappy
                # string comparison if that is the case.
                begin
                    leftV = Versionomy.parse(x['version']) 
                    rightV = Versionomy.parse(y['version'])
                    rightV <=> leftV
                rescue
                    # try again with shortversionstring
                    begin
                        leftV = Versionomy.parse(x['shortVersionString']) 
                        rightV = Versionomy.parse(y['shortVersionString']) 
                        rightV <=> leftV
                    rescue
                        # all else fails. just do string compare
                        y['version'] <=> x['version']
                    end
                end 
            end
        end

        if releases[0]['version']
            log.debug "'#{app.name}': 'v#{releases[0]['version']}' is most recent"
            update_avail = false
            begin
                existingV = Versionomy.parse(app.version)
                latestV = Versionomy.parse(releases[0]['version'])
                update_avail = latestV > existingV
                log.debug "'#{app.name}': versionomy compare"
            rescue
                # try again with shortversionstring
                begin
                    existingV = Versionomy.parse(app.shortVersionString) 
                    latestV = Versionomy.parse(releases[0]['shortVersionString']) 
                    update_avail = latestV > existingV
                    log.debug "'#{app.name}' resorted to shortVersionString compare"
                rescue
                    # all else fails. just do string compare
                    update_avail = releases[0]['version'] > app.version
                    log.debug "'#{app.name}' resorted to string compare"
                end
            end

            if update_avail
                new_ver = nice_version(
                    releases[0]['shortVersionString'], releases[0]['version'])
                log.debug "'#{app.name}': 'v#{releases[0]['version']}' is newer!"
                return [app.name, app.version_nice, new_ver]
            end
        end
        return nil
    end

    class Progress
        @@nullout = StringIO.new
        def @@nullout.write(str)
            return str.size
        end

        def initialize(title, max, output=true)
            if output
                out = STDERR
            else
                out = @@nullout
            end
            @pbar = ::ANSI::Progressbar.new(title, max, out)
            @pbar.format("%-14s %3d%% %s", :title, :percentage, :bar)
            @pbar.bar_mark = '='
        end
        
        def inc
            @pbar.inc
        end

        def finish
            @pbar.finish
        end

        def progress_reduce(iterable)
            coll = []
            progress(iterable) do |x|
                v = yield x
                if v
                    coll << v
                end
            end
            coll
        end

        def progress(iterable)
            @pbar.reset
            if block_given?
                iterable.each do |a| 
                    yield(a)
                    @pbar.inc
                end
            end
            @pbar.finish
            iterable
        end
    end
end
