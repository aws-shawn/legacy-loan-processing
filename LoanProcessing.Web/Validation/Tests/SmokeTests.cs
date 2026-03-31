using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Net.Http;
using LoanProcessing.Web.Validation.Models;

namespace LoanProcessing.Web.Validation.Tests
{
    /// <summary>
    /// Smoke tests that verify all application pages load correctly
    /// by making HTTP GET requests to each page and checking for
    /// expected status codes and content markers.
    /// </summary>
    public class SmokeTests : IValidationTestCategory
    {
        private readonly string _baseUrl;

        // Shared HttpClient avoids socket exhaustion on .NET Framework
        // and is the recommended pattern on .NET 8+.
        private static readonly HttpClient SharedClient = CreateHttpClient();

        public string CategoryName { get { return "Smoke"; } }

        /// <summary>
        /// Creates a new SmokeTests instance.
        /// </summary>
        /// <param name="baseUrl">
        /// Base URL of the application (e.g., "http://localhost:80").
        /// If null or empty, resolves to localhost on the current port,
        /// which avoids routing through a load balancer or reverse proxy.
        /// </param>
        public SmokeTests(string baseUrl = null)
        {
            if (string.IsNullOrWhiteSpace(baseUrl))
            {
                _baseUrl = ResolveBaseUrl();
            }
            else
            {
                _baseUrl = baseUrl.TrimEnd('/');
            }
        }

        private static HttpClient CreateHttpClient()
        {
            var client = new HttpClient();
            client.Timeout = TimeSpan.FromSeconds(10);
            return client;
        }

        public List<TestResult> Run(ModernizationStage stage)
        {
            var results = new List<TestResult>();

            results.Add(TestPage(stage, "/", "Home Page Loads", "Home",
                "Verifies that the Home page loads correctly and the application is serving requests",
                new[] { "Home", "LoanProcessing" }));

            results.Add(TestPage(stage, "/Customer", "Customers Page Loads", "Customers",
                "Verifies that the Customers page loads correctly and displays customer data",
                new[] { "Customers" }));

            results.Add(TestPage(stage, "/Loan", "Loans Page Loads", "Loan",
                "Verifies that the Loans page loads correctly and displays loan application data",
                new[] { "Loan" }));

            results.Add(TestPage(stage, "/Report/Portfolio", "Reports Page Loads", "Report",
                "Verifies that the Reports page loads correctly and displays reporting data",
                new[] { "Report" }));

            results.Add(TestPage(stage, "/InterestRate", "Interest Rates Page Loads", "Interest",
                "Verifies that the Interest Rates page loads correctly and displays rate data",
                new[] { "Interest" }));

            return results;
        }

        private TestResult TestPage(ModernizationStage stage, string path, string testName,
            string contentMarkerLabel, string description, string[] contentMarkers)
        {
            var sw = Stopwatch.StartNew();
            try
            {
                var url = _baseUrl + path;
                var response = SharedClient.GetAsync(url).Result;
                var statusCode = (int)response.StatusCode;
                var body = response.Content.ReadAsStringAsync().Result;
                sw.Stop();

                // Check status code
                if (statusCode != 200)
                {
                    return new TestResult
                    {
                        TestName = testName,
                        Category = CategoryName,
                        Description = description,
                        Passed = false,
                        Expected = "HTTP 200 OK",
                        Actual = "HTTP " + statusCode,
                        WhatToCheck = GetSmokeTestHint(stage),
                        Duration = sw.Elapsed
                    };
                }

                // Check content markers — at least one must be present
                bool foundMarker = false;
                foreach (var marker in contentMarkers)
                {
                    if (body.IndexOf(marker, StringComparison.OrdinalIgnoreCase) >= 0)
                    {
                        foundMarker = true;
                        break;
                    }
                }

                if (!foundMarker)
                {
                    return new TestResult
                    {
                        TestName = testName,
                        Category = CategoryName,
                        Description = description,
                        Passed = false,
                        Expected = "Page contains '" + contentMarkerLabel + "'",
                        Actual = "Content marker not found in response",
                        WhatToCheck = GetSmokeTestHint(stage),
                        Duration = sw.Elapsed
                    };
                }

                return new TestResult
                {
                    TestName = testName,
                    Category = CategoryName,
                    Description = description,
                    Passed = true,
                    Expected = "HTTP 200 with '" + contentMarkerLabel + "' content",
                    Actual = "HTTP 200 with '" + contentMarkerLabel + "' content",
                    WhatToCheck = string.Empty,
                    Duration = sw.Elapsed
                };
            }
            catch (Exception ex)
            {
                sw.Stop();
                var innerMessage = ex.InnerException != null ? ex.InnerException.Message : ex.Message;
                return new TestResult
                {
                    TestName = testName,
                    Category = CategoryName,
                    Description = description,
                    Passed = false,
                    Expected = "HTTP 200 OK",
                    Actual = "Connection failed: " + innerMessage,
                    WhatToCheck = GetSmokeTestHint(stage),
                    Duration = sw.Elapsed
                };
            }
        }

        private static string GetSmokeTestHint(ModernizationStage stage)
        {
            switch (stage)
            {
                case ModernizationStage.PreModernization:
                    return "Check that IIS is running and the application pool is started";
                case ModernizationStage.PostModule1:
                    return "Check that the application connection string was updated to Aurora PostgreSQL";
                case ModernizationStage.PostModule2:
                    return "Check that the .NET 8 application builds and runs with dotnet run";
                case ModernizationStage.PostModule3:
                    return "Check that the container is running and port mapping is correct";
                default:
                    return "Check that the application is running and accessible";
            }
        }

        /// <summary>
        /// Resolves the base URL for smoke test HTTP requests.
        /// Always targets localhost to avoid routing through a load balancer
        /// or reverse proxy, which would cause thread contention and timeouts.
        ///
        /// Works across all modernization stages:
        ///   - IIS on Windows (.NET Framework): HttpContext provides the port
        ///   - Kestrel on Linux (.NET 8): ASPNETCORE_URLS env var provides the port
        ///   - Container (.NET 8): same as above, typically port 8080
        /// </summary>
        private static string ResolveBaseUrl()
        {
            // Try HttpContext first (works on .NET Framework / IIS)
            try
            {
                var contextType = Type.GetType("System.Web.HttpContext, System.Web");
                if (contextType != null)
                {
                    var currentProp = contextType.GetProperty("Current",
                        System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Static);
                    if (currentProp != null)
                    {
                        var context = currentProp.GetValue(null);
                        if (context != null)
                        {
                            var requestProp = contextType.GetProperty("Request");
                            var request = requestProp != null ? requestProp.GetValue(context) : null;
                            if (request != null)
                            {
                                var urlProp = request.GetType().GetProperty("Url");
                                var url = urlProp != null ? urlProp.GetValue(request) as Uri : null;
                                if (url != null)
                                {
                                    return url.Scheme + "://localhost:" + url.Port;
                                }
                            }
                        }
                    }
                }
            }
            catch
            {
                // HttpContext not available — try next approach
            }

            // Try ASPNETCORE_URLS (works on .NET 8 / Kestrel / containers)
            try
            {
                var urls = Environment.GetEnvironmentVariable("ASPNETCORE_URLS");
                if (!string.IsNullOrEmpty(urls))
                {
                    // Take the first URL, replace the host with localhost
                    var firstUrl = urls.Split(';')[0].Trim();
                    var uri = new Uri(firstUrl.Replace("*", "localhost").Replace("+", "localhost").Replace("0.0.0.0", "localhost"));
                    return uri.Scheme + "://localhost:" + uri.Port;
                }
            }
            catch
            {
                // Env var not set or malformed — fall back
            }

            return "http://localhost";
        }
    }
}
