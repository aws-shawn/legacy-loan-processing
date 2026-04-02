# Implementation Plan: Credit Evaluation Extraction

## Overview

Extract the credit evaluation business logic from `sp_EvaluateCredit` into a C# service layer using the strangler pattern. The implementation proceeds bottom-up: pure calculation functions first, then repository extensions, then the service, then the wiring redirect. Each step compiles and the codebase remains functional throughout.

## Tasks

- [ ] 1. Create CreditEvaluationCalculator with pure computation functions
  - [ ] 1.1 Create `LoanProcessing.Web/Services/CreditEvaluationCalculator.cs` with static methods
    - Implement `CalculateDtiRatio(decimal existingDebt, decimal requestedAmount, decimal annualIncome)` returning `((existingDebt + requestedAmount) / annualIncome) * 100`
    - Implement `CalculateCreditScoreComponent(int creditScore)` with bracket mapping: ≥750→10, ≥700→20, ≥650→35, ≥600→50, <600→75
    - Implement `CalculateDtiComponent(decimal dtiRatio)` with bracket mapping: ≤20→0, ≤35→10, ≤43→20, >43→30
    - Implement `CalculateRiskScore(int creditScore, decimal dtiRatio)` as sum of components clamped to [0, 100]
    - Implement `DetermineRecommendation(int riskScore, decimal dtiRatio)` returning one of three recommendation strings
    - Define `DefaultInterestRate = 12.99m` constant
    - _Requirements: 1.3, 2.1, 2.2, 2.3, 2.4, 4.1, 4.2, 4.3_

- [ ] 2. Create test project and write property-based tests for calculator
  - [ ] 2.1 Create `LoanProcessing.Tests` xUnit test project targeting .NET Framework 4.7.2
    - Add project references to `LoanProcessing.Web`
    - Add NuGet packages: xunit, xunit.runner.visualstudio, FsCheck, FsCheck.Xunit, Moq
    - _Requirements: 8.1, 8.2, 8.3_

  - [ ]* 2.2 Write property test for DTI ratio calculation
    - **Property 1: DTI Ratio Calculation**
    - For any positive annualIncome, non-negative existingDebt, and positive requestedAmount, verify `CalculateDtiRatio` equals `((existingDebt + requestedAmount) / annualIncome) * 100`
    - **Validates: Requirements 1.2, 1.3, 8.2**

  - [ ]* 2.3 Write property test for credit score component bracket mapping
    - **Property 2: Credit Score Component Bracket Mapping**
    - For any credit score in [300, 850], verify `CalculateCreditScoreComponent` returns the correct bracket value
    - **Validates: Requirements 2.1, 8.1**

  - [ ]* 2.4 Write property test for DTI component bracket mapping
    - **Property 3: DTI Component Bracket Mapping**
    - For any non-negative DTI ratio, verify `CalculateDtiComponent` returns the correct bracket value
    - **Validates: Requirements 2.2, 8.1**

  - [ ]* 2.5 Write property test for risk score range invariant
    - **Property 4: Risk Score Range Invariant**
    - For any credit score in [300, 850] and non-negative DTI, verify `CalculateRiskScore` is in [0, 100] and equals the sum of components
    - **Validates: Requirements 2.3, 2.4, 8.1**

  - [ ]* 2.6 Write property test for recommendation classification
    - **Property 5: Recommendation Classification**
    - For any risk score in [0, 100] and non-negative DTI, verify `DetermineRecommendation` returns exactly one of the three valid recommendation strings with correct conditions
    - **Validates: Requirements 4.1, 4.2, 4.3, 8.3**

- [ ] 3. Checkpoint - Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 4. Extend repository interfaces and implementations with new methods
  - [ ] 4.1 Add `GetRateByCriteria` to `IInterestRateRepository` and implement in `InterestRateRepository`
    - Add method `InterestRate GetRateByCriteria(string loanType, int creditScore, int termMonths, DateTime asOfDate)` to the interface
    - Implement with SQL query: `SELECT TOP 1 ... WHERE LoanType = @LoanType AND @CreditScore BETWEEN MinCreditScore AND MaxCreditScore AND @TermMonths BETWEEN MinTermMonths AND MaxTermMonths AND EffectiveDate <= @AsOfDate AND (ExpirationDate IS NULL OR ExpirationDate >= @AsOfDate) ORDER BY EffectiveDate DESC`
    - Return null if no match found
    - _Requirements: 3.1, 3.2_

  - [ ] 4.2 Add `GetApprovedAmountsByCustomer` and `UpdateStatusAndRate` to `ILoanApplicationRepository` and implement in `LoanApplicationRepository`
    - Add `decimal GetApprovedAmountsByCustomer(int customerId, int excludeApplicationId)` — returns SUM of ApprovedAmount for approved applications excluding the given app
    - Add `void UpdateStatusAndRate(int applicationId, string status, decimal interestRate)` — updates Status and InterestRate columns
    - Implement both with direct SQL queries matching the stored procedure's behavior
    - _Requirements: 1.2, 5.1, 5.2_

  - [ ]* 4.3 Write property test for interest rate lookup correctness
    - **Property 6: Interest Rate Lookup Correctness**
    - Verify `GetRateByCriteria` returns the rate with the most recent EffectiveDate among matching records, or null if none match
    - Use mocked or in-memory data to test the selection logic
    - **Validates: Requirements 3.1, 3.2, 3.3, 8.4**

- [ ] 5. Create ICreditEvaluationService and CreditEvaluationService
  - [ ] 5.1 Create `LoanProcessing.Web/Services/ICreditEvaluationService.cs`
    - Define `LoanDecision Evaluate(int applicationId)` method
    - _Requirements: 9.1_

  - [ ] 5.2 Create `LoanProcessing.Web/Services/CreditEvaluationService.cs`
    - Constructor takes `ILoanApplicationRepository`, `ICustomerRepository`, `IInterestRateRepository`
    - Implement `Evaluate(int applicationId)`:
      1. Validate applicationId > 0, throw `ArgumentException` if not
      2. Load application via `_loanAppRepo.GetById(applicationId)`, throw `InvalidOperationException` if null
      3. Load customer via `_customerRepo.GetById(application.CustomerId)`, throw `InvalidOperationException` if null
      4. Validate customer.AnnualIncome > 0, throw `InvalidOperationException` if not
      5. Get existing debt via `_loanAppRepo.GetApprovedAmountsByCustomer(customerId, applicationId)`
      6. Calculate DTI, risk score, recommendation via `CreditEvaluationCalculator`
      7. Look up rate via `_rateRepo.GetRateByCriteria(...)`, default to 12.99% if null
      8. Update application via `_loanAppRepo.UpdateStatusAndRate(applicationId, "UnderReview", rate)`
      9. Return populated `LoanDecision` with ApplicationId, RiskScore, DebtToIncomeRatio, InterestRate, Comments (recommendation)
    - _Requirements: 1.1, 1.2, 1.3, 1.4, 3.3, 5.1, 5.2, 5.3, 6.1, 6.2, 6.3, 9.2, 9.3_

  - [ ]* 5.3 Write unit tests for CreditEvaluationService
    - Test error cases: null application, null customer, zero/negative income, invalid applicationId
    - Test default rate fallback when no matching rate found
    - Test that UpdateStatusAndRate is called with "UnderReview" and the determined rate
    - Test output completeness: all LoanDecision fields are populated
    - Use Moq to mock repository interfaces
    - **Property 7: Evaluation Output Completeness**
    - **Validates: Requirements 1.4, 3.3, 5.1, 5.2, 6.1, 6.2, 6.3**

- [ ] 6. Checkpoint - Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 7. Redirect LoanDecisionRepository to use CreditEvaluationService
  - [ ] 7.1 Modify `LoanDecisionRepository` to accept and use `ICreditEvaluationService`
    - Add `ICreditEvaluationService _creditEvalService` field
    - Add new constructor: `LoanDecisionRepository(string connectionString, ICreditEvaluationService creditEvalService)`
    - Update parameterless constructor to wire the full dependency chain: create `LoanApplicationRepository`, `CustomerRepository`, `InterestRateRepository`, then `CreditEvaluationService`, passing them in
    - Update `LoanDecisionRepository(string connectionString)` constructor to also wire the chain using the provided connection string
    - Replace `EvaluateCredit` body: remove all `sp_EvaluateCredit` ADO.NET code, delegate to `_creditEvalService.Evaluate(applicationId)`
    - _Requirements: 7.1, 7.2, 7.3_

  - [ ] 7.2 Update `ValidationService` constructor wiring
    - In `ValidationService(string connectionString)`, the `LoanDecisionRepository` is created with `new LoanDecisionRepository(connectionString)` — ensure this constructor now also wires up the `CreditEvaluationService` chain internally
    - No changes to `LoanService` constructor call or any other wiring
    - _Requirements: 7.3, 8.5_

- [ ] 8. Final checkpoint - Ensure all tests pass and existing validation tests are unmodified
  - Ensure all tests pass, ask the user if questions arise.
  - Verify `CreditEvaluationTests.cs` and `LoanProcessingTests.cs` have zero modifications
  - Verify `LoanService.cs` has zero modifications
  - _Requirements: 7.3, 8.5_

## Notes

- Tasks marked with `*` are optional and can be skipped for faster MVP
- Each task references specific requirements for traceability
- Checkpoints ensure incremental validation
- Property tests validate universal correctness properties from the design document
- The existing validation tests (`CreditEvaluationTests`, `LoanProcessingTests`) serve as the behavioral equivalence gate and must pass without modification
- The `sp_EvaluateCredit` stored procedure remains in the database unchanged for rollback purposes
