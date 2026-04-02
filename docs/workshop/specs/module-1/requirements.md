# Requirements Document

## Introduction

This document defines the requirements for extracting the credit evaluation business logic from the `sp_EvaluateCredit` SQL Server stored procedure into the .NET service layer. This is the first module of a strangler pattern migration: the stored procedure remains in the database but is no longer invoked. Instead, the `CreditEvaluationService` performs all credit evaluation computations in C# code, reading data through the repository layer and writing results back via SQL. The extraction establishes the pattern for migrating the remaining stored procedures (`sp_ProcessLoanDecision`, `sp_CalculatePaymentSchedule`, `sp_GeneratePortfolioReport`). The application continues to run on Windows EC2 / IIS / SQL Server throughout this step.

## Glossary

- **CreditEvaluationService**: A new .NET service class that implements the credit evaluation business logic previously contained in `sp_EvaluateCredit`.
- **ICreditEvaluationService**: The interface for the CreditEvaluationService, enabling dependency injection and testability.
- **LoanDecisionRepository**: The existing repository class (`LoanProcessing.Web.Data.LoanDecisionRepository`) that currently calls `sp_EvaluateCredit` and will be updated to delegate to the CreditEvaluationService.
- **LoanService**: The existing service class (`LoanProcessing.Web.Services.LoanService`) that orchestrates loan operations and calls `ILoanDecisionRepository.EvaluateCredit`.
- **DTI_Ratio**: Debt-to-Income Ratio, calculated as `((ExistingApprovedDebt + RequestedAmount) / AnnualIncome) * 100`.
- **Risk_Score**: A numeric score from 0 to 100 (lower is better) derived from a credit score component and a DTI component.
- **Credit_Score_Component**: The portion of the Risk_Score determined by the customer's credit score bracket.
- **DTI_Component**: The portion of the Risk_Score determined by the DTI_Ratio bracket.
- **Interest_Rate_Lookup**: The process of selecting an applicable interest rate from the InterestRates table based on loan type, credit score, term, and effective date.
- **Recommendation**: A text classification of the evaluation result: "Recommended for Approval", "Manual Review Required", or "High Risk - Recommend Rejection".
- **Strangler_Pattern**: A migration strategy where new functionality is built alongside the legacy implementation, and traffic is redirected incrementally until the legacy code is no longer called.
- **Validation_Test_Framework**: The existing test suite (`CreditEvaluationTests`, `LoanProcessingTests`) that exercises credit evaluation code paths and verifies behavioral equivalence.

## Requirements

### Requirement 1: Extract DTI Ratio Calculation

**User Story:** As a developer, I want the debt-to-income ratio calculation to be implemented in C# service code, so that the business logic is testable and maintainable outside the database.

#### Acceptance Criteria

1. WHEN a loan application ID is provided, THE CreditEvaluationService SHALL retrieve the customer's annual income and the requested loan amount from the database via the repository layer.
2. WHEN calculating existing debt, THE CreditEvaluationService SHALL sum the approved amounts of all other approved loan applications for the same customer, excluding the current application.
3. THE CreditEvaluationService SHALL compute the DTI_Ratio as `((ExistingApprovedDebt + RequestedAmount) / AnnualIncome) * 100`.
4. IF the customer's annual income is zero or negative, THEN THE CreditEvaluationService SHALL return a descriptive error indicating that income data is invalid.

### Requirement 2: Extract Risk Score Calculation

**User Story:** As a developer, I want the risk scoring logic to be implemented in C# service code, so that scoring rules can be modified and tested without database deployments.

#### Acceptance Criteria

1. THE CreditEvaluationService SHALL compute the Credit_Score_Component using the following brackets: credit score >= 750 yields 10, >= 700 yields 20, >= 650 yields 35, >= 600 yields 50, below 600 yields 75.
2. THE CreditEvaluationService SHALL compute the DTI_Component using the following brackets: DTI_Ratio <= 20 yields 0, <= 35 yields 10, <= 43 yields 20, above 43 yields 30.
3. THE CreditEvaluationService SHALL compute the Risk_Score as the sum of Credit_Score_Component and DTI_Component.
4. THE CreditEvaluationService SHALL constrain the Risk_Score to the range 0 through 100.

### Requirement 3: Extract Interest Rate Lookup

**User Story:** As a developer, I want the interest rate lookup to be performed in C# service code, so that rate selection logic is transparent and unit-testable.

#### Acceptance Criteria

1. WHEN determining the interest rate, THE CreditEvaluationService SHALL query the InterestRates table for a rate matching the loan type, where the customer's credit score falls within the MinCreditScore and MaxCreditScore range, the term months falls within the MinTermMonths and MaxTermMonths range, the EffectiveDate is on or before the current date, and the ExpirationDate is null or on or after the current date.
2. WHEN multiple matching rates exist, THE CreditEvaluationService SHALL select the rate with the most recent EffectiveDate.
3. IF no matching interest rate is found, THEN THE CreditEvaluationService SHALL use a default rate of 12.99%.

### Requirement 4: Generate Evaluation Recommendation

**User Story:** As a developer, I want the recommendation logic to be implemented in C# service code, so that approval thresholds are clearly expressed in application code.

#### Acceptance Criteria

1. WHEN the Risk_Score is 30 or below and the DTI_Ratio is 35 or below, THE CreditEvaluationService SHALL return a Recommendation of "Recommended for Approval".
2. WHEN the Risk_Score is 50 or below and the DTI_Ratio is 43 or below and the criteria for "Recommended for Approval" are not met, THE CreditEvaluationService SHALL return a Recommendation of "Manual Review Required".
3. WHEN neither the "Recommended for Approval" nor the "Manual Review Required" criteria are met, THE CreditEvaluationService SHALL return a Recommendation of "High Risk - Recommend Rejection".

### Requirement 5: Update Application Status

**User Story:** As a developer, I want the application status update to happen as part of the service-layer evaluation, so that the evaluation workflow remains atomic and consistent.

#### Acceptance Criteria

1. WHEN credit evaluation completes successfully, THE CreditEvaluationService SHALL update the loan application status to "UnderReview" in the database.
2. WHEN credit evaluation completes successfully, THE CreditEvaluationService SHALL update the loan application's interest rate to the determined rate in the database.
3. IF the database update fails, THEN THE CreditEvaluationService SHALL propagate a descriptive error and leave the application in its previous state.

### Requirement 6: Return Evaluation Results

**User Story:** As a developer, I want the evaluation to return a complete LoanDecision object, so that callers receive the same data structure as the stored procedure produced.

#### Acceptance Criteria

1. THE CreditEvaluationService SHALL return a LoanDecision containing ApplicationId, RiskScore, DebtToIncomeRatio, InterestRate, and Recommendation (in the Comments field).
2. THE CreditEvaluationService SHALL populate the LoanDecision with the customer's CreditScore, ExistingDebt, RequestedAmount, and AnnualIncome used in the evaluation.
3. IF the specified loan application does not exist, THEN THE CreditEvaluationService SHALL return a descriptive error indicating the application was not found.

### Requirement 7: Redirect Repository to Service Layer

**User Story:** As a developer, I want the LoanDecisionRepository.EvaluateCredit method to call the new CreditEvaluationService instead of sp_EvaluateCredit, so that the stored procedure is no longer invoked at runtime.

#### Acceptance Criteria

1. WHEN `EvaluateCredit` is called on the LoanDecisionRepository, THE LoanDecisionRepository SHALL delegate to the CreditEvaluationService instead of executing the `sp_EvaluateCredit` stored procedure.
2. THE `sp_EvaluateCredit` stored procedure SHALL remain in the database unchanged for rollback purposes.
3. THE LoanService SHALL continue to call `ILoanDecisionRepository.EvaluateCredit` with no changes to the LoanService code.

### Requirement 8: Maintain Behavioral Equivalence

**User Story:** As a developer, I want the extracted service to produce identical results to the stored procedure, so that the migration introduces no regressions.

#### Acceptance Criteria

1. FOR ALL valid loan applications, THE CreditEvaluationService SHALL produce the same RiskScore as `sp_EvaluateCredit` for identical input data.
2. FOR ALL valid loan applications, THE CreditEvaluationService SHALL produce the same DTI_Ratio as `sp_EvaluateCredit` for identical input data.
3. FOR ALL valid loan applications, THE CreditEvaluationService SHALL produce the same Recommendation as `sp_EvaluateCredit` for identical input data.
4. FOR ALL valid loan applications, THE CreditEvaluationService SHALL select the same InterestRate as `sp_EvaluateCredit` for identical input data.
5. THE Validation_Test_Framework (CreditEvaluationTests and LoanProcessingTests) SHALL pass with no modifications after the extraction.

### Requirement 9: Establish Extraction Pattern for Remaining Procedures

**User Story:** As a developer, I want this extraction to establish a repeatable pattern, so that the remaining stored procedures can be migrated consistently.

#### Acceptance Criteria

1. THE CreditEvaluationService SHALL be implemented behind an ICreditEvaluationService interface registered in the dependency injection container.
2. THE CreditEvaluationService SHALL depend on repository interfaces (ILoanApplicationRepository, ICustomerRepository, IInterestRateRepository) rather than direct database access.
3. THE CreditEvaluationService SHALL reside in the `LoanProcessing.Web.Services` namespace alongside the existing service classes.
