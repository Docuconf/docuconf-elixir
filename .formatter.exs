locals_without_parens = [
  env: 2,
  env: 3,
  secret: 2,
  secret: 3,
  config_file: 2,
  tls_file: 2,
  ca_bundle_file: 2,
  keystore_file: 2,
  text_file: 2,
  binary_file: 2
]

[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: locals_without_parens,
  export: [locals_without_parens: locals_without_parens]
]
