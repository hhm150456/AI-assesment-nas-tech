class ApiConfig {
  const ApiConfig._();

  static const apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://ai-assesment-nas-tech-proxy.vercel.api',
  );
}
