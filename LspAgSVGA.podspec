Pod::Spec.new do |s|
  s.name             = 'LspAgSVGA'
  s.version          = '0.2.0'
  s.summary          = 'SVGA 2.x decoding and UIKit playback for iOS.'
  s.homepage         = 'https://github.com/ZMsQRT/LspAgSVGA'
  s.license          = { :type => 'Proprietary', :text => 'Copyright Moven. All rights reserved.' }
  s.author           = 'Moven'
  s.source           = { :git => 'https://github.com/ZMsQRT/LspAgSVGA.git', :tag => s.version.to_s }
  s.platform         = :ios, '17.0'
  s.swift_version    = '6.0'
  s.source_files     = 'LspAgSVGA.swift'
  s.frameworks       = 'UIKit'
  s.libraries        = 'z'
  s.static_framework = true

  s.test_spec 'Tests' do |tests|
    tests.source_files = 'LspAgSVGATests.swift'
  end
end
