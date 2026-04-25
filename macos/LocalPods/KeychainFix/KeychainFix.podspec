Pod::Spec.new do |s|
  s.name         = 'KeychainFix'
  s.version      = '1.0.0'
  s.summary      = 'macOS 26 keychain data protection fix'
  s.homepage     = 'https://local'
  s.license      = 'MIT'
  s.author       = 'local'
  s.platform     = :osx, '11.0'
  s.source       = { :path => '.' }
  s.source_files = '*.{h,m,c}'
  s.frameworks   = 'Security', 'Foundation'
end
