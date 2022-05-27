#
#  Be sure to run `pod spec lint RollbarPLCrashReporter.podspec' to ensure this is a valid spec.
#
#  To learn more about Podspec attributes see https://guides.cocoapods.org/syntax/podspec.html
#  To see working Podspecs in the CocoaPods repo see https://github.com/CocoaPods/Specs/
#

Pod::Spec.new do |s|

    s.version      = "2.3.2"
    s.name         = "RollbarCocoaLumberjack"
    s.summary      = "Application or client side SDK for interacting with the Rollbar API Server."
    s.description  = <<-DESC
                      Find, fix, and resolve errors with Rollbar.
                      Easily send error data using Rollbar API.
                      Analyze, de-dupe, send alerts, and prepare the data for further analysis.
                      Search, sort, and prioritize via the Rollbar dashboard.
                   DESC
    s.homepage     = "https://rollbar.com"
    # s.screenshots  = "www.example.com/screenshots_1.gif", "www.example.com/screenshots_2.gif"
    s.license      = { :type => "MIT", :file => "LICENSE" }
    # s.license      = "MIT (example)"
    s.documentation_url = "https://docs.rollbar.com/docs/apple"
    s.authors            = { "Andrey Kornich (Wide Spectrum Computing LLC)" => "akornich@gmail.com",
                              "Rollbar" => "support@rollbar.com" }
    # s.author             = { "Andrey Kornich" => "akornich@gmail.com" }
    # Or just: s.author    = "Andrey Kornich"
    s.social_media_url   = "http://twitter.com/rollbar"
    s.source             = { :git => "https://github.com/rollbar/rollbar-apple.git",
                             :tag => "#{s.version}"
                             }
    s.resource = "rollbar-logo.png"
    # s.resources = "Resources/*.png"

    #  When using multiple platforms:
    s.osx.deployment_target = "10.15"
    s.ios.deployment_target = "13.0"
    s.tvos.deployment_target = "13.0"
    s.watchos.deployment_target = "7.0"
    # Any platform, if omitted:
    # s.platform     = :ios
    # s.platform     = :ios, "5.0"

    s.source_files  = "#{s.name}/Sources/#{s.name}/**/*.{h,m}"
    s.public_header_files = "#{s.name}/Sources/#{s.name}/include/*.h"
    s.module_map = "#{s.name}/Sources/#{s.name}/include/module.modulemap"
    # s.exclude_files = "Classes/Exclude"
    # s.preserve_paths = "FilesToSave", "MoreFilesToSave"

    s.static_framework = true
    s.framework = "Foundation"
    s.dependency "RollbarCommon", "~> #{s.version}"
    s.dependency "RollbarNotifier", "~> #{s.version}"
    s.dependency "CocoaLumberjack", "~> 3.7.4"
    # s.frameworks = "SomeFramework", "AnotherFramework"
    # s.library   = "iconv"
    # s.libraries = "iconv", "xml2"
    # s.dependency "JSONKit", "~> 1.4"
    
    s.requires_arc = true
    # s.xcconfig = {
    #   "USE_HEADERMAP" => "NO",
    #   "HEADER_SEARCH_PATHS" => "$(PODS_ROOT)/Sources/#{s.name}/**"
    # }

    # s.pod_target_xcconfig  = { "ONLY_ACTIVE_ARCH" => "YES", "EXCLUDED_ARCHS[sdk=iphonesimulator*]" => "arm64" }
    # s.user_target_xcconfig = { "ONLY_ACTIVE_ARCH" => "YES", "EXCLUDED_ARCHS[sdk=iphonesimulator*]" => "arm64" }

    # s.tvos.pod_target_xcconfig  = { "ONLY_ACTIVE_ARCH" => "YES", "EXCLUDED_ARCHS[sdk=appletvsimulator*]" => "arm64" }
    # s.tvos.user_target_xcconfig = { "ONLY_ACTIVE_ARCH" => "YES", "EXCLUDED_ARCHS[sdk=appletvsimulator*]" => "arm64" }

end
