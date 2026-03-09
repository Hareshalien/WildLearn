

/// After deploying the backend with deploy.sh, paste the Cloud Run URL below.
/// Example: 'https://wild-backend-abc123.run.app'
///
/// Leave trailing slashes off the URL.

class Config {
  /// The base URL of your deployed Cloud Run backend.
  /// Replace this with the URL printed at the end of deploy.sh.
  static const String backendUrl =
      'YOUR_CLOUD_RUN_URL_HERE';
}
