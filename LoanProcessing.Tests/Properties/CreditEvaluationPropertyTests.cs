using System;
using FsCheck;
using FsCheck.Xunit;
using LoanProcessing.Web.Services;
using Xunit;

namespace LoanProcessing.Tests.Properties
{
    /// <summary>
    /// Property-based tests for CreditEvaluationCalculator pure functions.
    /// Each test validates a correctness property from the design document
    /// across 100 randomly generated inputs using FsCheck.
    /// </summary>
    public class CreditEvaluationPropertyTests
    {
        // Feature: credit-evaluation-extraction, Property 1: DTI Ratio Calculation
        // **Validates: Requirements 1.2, 1.3, 8.2**
        [Property(MaxTest = 100)]
        public Property DtiRatio_MatchesFormula()
        {
            return Prop.ForAll(
                Arb.From(Gen.Choose(1, 500000).Select(x => (decimal)x)),       // annualIncome (positive)
                Arb.From(Gen.Choose(0, 1000000).Select(x => (decimal)x)),      // existingDebt (non-negative)
                Arb.From(Gen.Choose(1, 500000).Select(x => (decimal)x)),       // requestedAmount (positive)
                (annualIncome, existingDebt, requestedAmount) =>
                {
                    decimal expected = ((existingDebt + requestedAmount) / annualIncome) * 100m;
                    decimal actual = CreditEvaluationCalculator.CalculateDtiRatio(existingDebt, requestedAmount, annualIncome);
                    return actual == expected;
                });
        }

        // Feature: credit-evaluation-extraction, Property 2: Credit Score Component Bracket Mapping
        // **Validates: Requirements 2.1, 8.1**
        [Property(MaxTest = 100)]
        public Property CreditScoreComponent_MapsToCorrectBracket()
        {
            return Prop.ForAll(
                Arb.From(Gen.Choose(300, 850)),
                (int creditScore) =>
                {
                    int result = CreditEvaluationCalculator.CalculateCreditScoreComponent(creditScore);

                    int expected;
                    if (creditScore >= 750) expected = 10;
                    else if (creditScore >= 700) expected = 20;
                    else if (creditScore >= 650) expected = 35;
                    else if (creditScore >= 600) expected = 50;
                    else expected = 75;

                    return result == expected;
                });
        }

        // Feature: credit-evaluation-extraction, Property 3: DTI Component Bracket Mapping
        // **Validates: Requirements 2.2, 8.1**
        [Property(MaxTest = 100)]
        public Property DtiComponent_MapsToCorrectBracket()
        {
            return Prop.ForAll(
                Arb.From(Gen.Choose(0, 200).Select(x => (decimal)x)),
                (decimal dtiRatio) =>
                {
                    int result = CreditEvaluationCalculator.CalculateDtiComponent(dtiRatio);

                    int expected;
                    if (dtiRatio <= 20m) expected = 0;
                    else if (dtiRatio <= 35m) expected = 10;
                    else if (dtiRatio <= 43m) expected = 20;
                    else expected = 30;

                    return result == expected;
                });
        }

        // Feature: credit-evaluation-extraction, Property 4: Risk Score Range Invariant
        // **Validates: Requirements 2.3, 2.4, 8.1**
        [Property(MaxTest = 100)]
        public Property RiskScore_InRangeAndEqualsComponentSum()
        {
            return Prop.ForAll(
                Arb.From(Gen.Choose(300, 850)),
                Arb.From(Gen.Choose(0, 200).Select(x => (decimal)x)),
                (int creditScore, decimal dtiRatio) =>
                {
                    int riskScore = CreditEvaluationCalculator.CalculateRiskScore(creditScore, dtiRatio);

                    // Must be in [0, 100]
                    bool inRange = riskScore >= 0 && riskScore <= 100;

                    // Must equal sum of components (clamped)
                    int expectedRaw = CreditEvaluationCalculator.CalculateCreditScoreComponent(creditScore)
                                    + CreditEvaluationCalculator.CalculateDtiComponent(dtiRatio);
                    int expectedClamped = Math.Min(100, Math.Max(0, expectedRaw));

                    return inRange && riskScore == expectedClamped;
                });
        }

        // Feature: credit-evaluation-extraction, Property 5: Recommendation Classification
        // **Validates: Requirements 4.1, 4.2, 4.3, 8.3**
        [Property(MaxTest = 100)]
        public Property Recommendation_ClassifiesCorrectly()
        {
            return Prop.ForAll(
                Arb.From(Gen.Choose(0, 100)),
                Arb.From(Gen.Choose(0, 200).Select(x => (decimal)x)),
                (int riskScore, decimal dtiRatio) =>
                {
                    string result = CreditEvaluationCalculator.DetermineRecommendation(riskScore, dtiRatio);

                    // Must be exactly one of the three valid values
                    bool isValidValue = result == "Recommended for Approval"
                                     || result == "Manual Review Required"
                                     || result == "High Risk - Recommend Rejection";

                    // Verify correct classification
                    string expected;
                    if (riskScore <= 30 && dtiRatio <= 35m)
                        expected = "Recommended for Approval";
                    else if (riskScore <= 50 && dtiRatio <= 43m)
                        expected = "Manual Review Required";
                    else
                        expected = "High Risk - Recommend Rejection";

                    return isValidValue && result == expected;
                });
        }
    }
}
