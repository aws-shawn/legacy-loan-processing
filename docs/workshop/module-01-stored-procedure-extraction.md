# Module 1: Business Logic Extraction (Strangler Pattern)

## 1. Overview

### What You Will Accomplish

In this module, you will extract the credit evaluation business logic from the `sp_EvaluateCredit` SQL Server stored procedure into the .NET service layer using the strangler pattern. You will use Kiro's spec-driven development workflow to plan, implement, and validate the extraction — then fast-forward the remaining stored procedure extractions using pre-built code. By the end, all business logic lives in testable C# code, and the database is reduced to a pure data store.

### Why This Matters

- Business logic locked in stored procedures can't be unit tested, can't run without SQL Server, and can't be exposed as an API or agent tool
- After extraction, the same logic is testable, database-agnostic, and shaped like a future microservice or AI agent tool
- The validation framework proves nothing broke — zero regressions across the entire application

### Estimated Time

60–90 minutes

### Tools Used

- Kiro (spec-driven development, AI-assisted code generation)
- Validation Test Framework (built into the application)

---

## 2. Prerequisites

### Expected Starting State

- EC2 Windows Server instance running IIS with the LoanProcessing .NET Framework 4.7.2 MVC application
- SQL Server database with 5 tables and 9 stored procedures
- Application Load Balancer routing traffic to the EC2 instance
- Application is accessible and all pages render correctly
- Validation tests pass (run from `/validation` endpoint)

### Lab Setup — Install the Kiro Spec

The spec documents for this module are provided in the repo. Copy them into your Kiro workspace:

```bash
mkdir -p .kiro/specs/credit-evaluation-extraction
cp docs/workshop/specs/module-1/* .kiro/specs/credit-evaluation-extraction/
```

This gives Kiro the requirements, design, and implementation tasks for the extraction.

### Verification

Open the application in your browser and navigate to the `/validation` page. Click "Run All Tests" and confirm all tests pass with a green status. This establishes your baseline.

---

## 3. Architecture

### Before — Business Logic in Stored Procedures

```
Browser → ALB → IIS (.NET 4.7.2)
                    │
                    ├── LoanController
                    │       └── LoanService.EvaluateCredit()
                    │               └── LoanDecisionRepository.EvaluateCredit()
                    │                       └── SQL Server: EXEC sp_EvaluateCredit
                    │                           (risk scoring, DTI calc, rate lookup,
                    │                            recommendation — all in T-SQL)
                    │
                    └── SQL Server: 9 stored procedures with business logic
```

### After — Business Logic in .NET Service Layer

```
Browser → ALB → IIS (.NET 4.7.2)
                    │
                    ├── LoanController
                    │       └── LoanService.EvaluateCredit()
                    │               └── LoanDecisionRepository.EvaluateCredit()
                    │                       └── CreditEvaluationService.Evaluate()
                    │                           ├── CustomerRepository (data only)
                    │                           ├── LoanApplicationRepository (data only)
                    │                           ├── InterestRateRepository (data only)
                    │                           └── CreditEvaluationCalculator (pure C#)
                    │
                    └── SQL Server: tables + data only (stored procedures unused)
```

---

## 4. Explore the Current Architecture (10–15 min)

Before changing anything, understand what you're working with.

### 4.1 — Examine the Stored Procedure

Open `LoanProcessing.Database/StoredProcedures/sp_EvaluateCredit.sql` and read through it. Notice:

- **Lines 27–31** — Validation: checks if the application exists, raises an error if not
- **Lines 34–43** — Loads application and customer data by joining LoanApplications to Customers (credit score, annual income, requested amount, loan type, term)
- **Lines 46–50** — Calculates existing debt by summing approved loan amounts for the same customer, excluding the current application
- **Line 53** — Computes DTI ratio: `((ExistingDebt + RequestedAmount) / AnnualIncome) * 100`
- **Lines 57–64** — Credit score component: bracket-based CASE statement (750+→10, 700+→20, 650+→35, 600+→50, <600→75)
- **Lines 68–74** — DTI component: bracket-based CASE statement (≤20→0, ≤35→10, ≤43→20, >43→30)
- **Line 77** — Total risk score = credit score component + DTI component
- **Lines 80–86** — Interest rate lookup: SELECT TOP 1 from InterestRates matching loan type, credit score range, term range, and effective date
- **Lines 89–92** — Default rate fallback: 12.99% if no matching rate found
- **Lines 95–98** — Updates application status to "UnderReview" and sets the interest rate
- **Lines 101–112** — Returns result set with evaluation data and recommendation (another CASE statement on risk score and DTI)

This is a self-contained business operation — perfect for extraction.

### 4.2 — Trace the Call Chain

Follow the code path from controller to database. This is the path that credit evaluation takes today:

**Step 1: Controller** — `LoanProcessing.Web/Controllers/LoanController.cs`

Look at the `Evaluate` action method (line 253). When a user triggers credit evaluation, the controller calls:

```csharp
var evaluation = _loanService.EvaluateCredit(id.Value);
```

The controller doesn't know anything about stored procedures or databases — it just calls the service. Also note the constructor (lines 27–37) where dependencies are wired manually. This is the legacy DI pattern you'll see throughout the project.

**Step 2: Service** — `LoanProcessing.Web/Services/LoanService.cs`

Look at the `EvaluateCredit` method (line 174). It validates the input and delegates to the repository:

```csharp
var result = _decisionRepo.EvaluateCredit(applicationId);
```

This method won't change during the extraction — it calls `ILoanDecisionRepository.EvaluateCredit` and doesn't care what happens behind that interface. That's the key insight for the strangler pattern.

**Step 3: Repository (the strangler point)** — `LoanProcessing.Web/Data/LoanDecisionRepository.cs`

Look at the `EvaluateCredit` method (lines 55–89). This is where the stored procedure is called:

```csharp
using (var command = new SqlCommand("sp_EvaluateCredit", connection))
{
    command.CommandType = CommandType.StoredProcedure;
    command.Parameters.AddWithValue("@ApplicationId", applicationId);
    // ... executes the stored procedure and maps the result set
}
```

This is the single point we'll redirect. After extraction, this method will delegate to `CreditEvaluationService.Evaluate()` instead of calling `sp_EvaluateCredit`. Everything above (controller, service) stays untouched.

**Key takeaway:** The repository is the integration seam. The strangler pattern works because the service layer depends on an interface (`ILoanDecisionRepository`), not on the stored procedure directly. We swap the implementation behind the interface, and nothing else needs to change.

Also review the supporting interfaces and models to understand the data flow:

- `LoanProcessing.Web/Services/ILoanService.cs` — the service interface with `EvaluateCredit(int applicationId)`
- `LoanProcessing.Web/Data/ILoanDecisionRepository.cs` — the repository interface
- `LoanProcessing.Web/Models/LoanDecision.cs` — the return type (RiskScore, DebtToIncomeRatio, InterestRate, Comments)
- `LoanProcessing.Web/Models/LoanApplication.cs` — the input entity (CustomerId, LoanType, RequestedAmount, TermMonths)
- `LoanProcessing.Web/Models/Customer.cs` — customer data (CreditScore, AnnualIncome)
- `LoanProcessing.Web/Models/InterestRate.cs` — rate lookup entity (LoanType, MinCreditScore, MaxCreditScore, Rate, EffectiveDate)

### 4.3 — Review the Existing Repository and Service Wiring

Understand how dependencies are currently wired (this project uses manual constructor injection, no DI container):

- `LoanProcessing.Web/Data/CustomerRepository.cs` — calls stored procedures for customer CRUD
- `LoanProcessing.Web/Data/LoanApplicationRepository.cs` — calls stored procedures for loan operations
- `LoanProcessing.Web/Data/InterestRateRepository.cs` — direct SQL for interest rate operations
- `LoanProcessing.Web/Data/ICustomerRepository.cs` — customer repository interface
- `LoanProcessing.Web/Data/ILoanApplicationRepository.cs` — loan application repository interface
- `LoanProcessing.Web/Data/IInterestRateRepository.cs` — interest rate repository interface
- `LoanProcessing.Web/Validation/ValidationService.cs` — wires up all repositories and services manually in its constructor

### 4.4 — Review the Validation Tests

These are the tests that must continue to pass after the extraction:

- `LoanProcessing.Web/Validation/Tests/CreditEvaluationTests.cs` — tests high/low credit scores and DTI ratio
- `LoanProcessing.Web/Validation/Tests/LoanProcessingTests.cs` — tests loan submission, credit evaluation, decision processing, payment schedule, and portfolio report

### 4.5 — Run the Validation Baseline

Navigate to `/validation` in your browser and click "Run All Tests." Note the results:

- Smoke tests: all pages load
- Data integrity: row counts and constraints verified
- Business logic: customer CRUD, loan processing, credit evaluation, portfolio reports

These tests will be your proof that the extraction didn't break anything.

### Takeaways

After exploring the code, you should understand three things:

1. **Where the business logic lives today** — inside `sp_EvaluateCredit`, a 120-line T-SQL stored procedure that does validation, data loading, DTI calculation, risk scoring, rate lookup, status updates, and recommendation generation all in one transaction.

2. **Where the strangler seam is** — `LoanDecisionRepository.EvaluateCredit` (line 55) is the single method that calls the stored procedure. Everything above it (LoanService, LoanController) depends on interfaces, not on the stored procedure.

3. **How you'll prove it worked** — the validation tests exercise the full credit evaluation pipeline. If they pass after the extraction, the behavior is identical.

---

## 5. Review the Spec (10–15 min)

The extraction is driven by a Kiro spec. Open and review each document to understand the plan before executing it.

### 5.1 — Requirements Document

Open `.kiro/specs/credit-evaluation-extraction/requirements.md`

(If you haven't installed the spec yet, run the setup command from Section 2.)

This document defines 9 requirements covering:
- DTI ratio calculation
- Risk score computation
- Interest rate lookup
- Recommendation generation
- Application status updates
- Behavioral equivalence with the stored procedure
- The repeatable pattern for future extractions

Notice how each requirement maps to a specific piece of the stored procedure logic. The strangler pattern works because we can verify each piece independently.

### 5.2 — Design Document

Open `.kiro/specs/credit-evaluation-extraction/design.md`

Key design decisions to discuss:

- **CreditEvaluationCalculator** — Pure static functions for DTI, risk score, and recommendation. No database dependencies. These are trivially unit-testable and property-testable. Notice how they're shaped like agent tools — clear inputs, deterministic outputs.

- **CreditEvaluationService** — Orchestrates the evaluation by calling repositories for data and the calculator for computation. Depends only on interfaces, not concrete classes.

- **Repository redirect** — `LoanDecisionRepository.EvaluateCredit` is the single point of change. It stops calling `sp_EvaluateCredit` and delegates to `CreditEvaluationService.Evaluate` instead. `LoanService` is completely untouched.

### 5.3 — Implementation Tasks

Open `.kiro/specs/credit-evaluation-extraction/tasks.md`

The tasks are ordered bottom-up so the codebase compiles at every step:
1. Pure calculator functions (no dependencies)
2. Repository interface extensions (new data access methods)
3. Service implementation (orchestrates calculator + repositories)
4. Repository redirect (the strangler switch)
5. Final validation

---

## 6. Execute the Extraction with Kiro (20–25 min)

### Getting Started with Kiro Task Execution

If this is your first time using Kiro's spec-driven workflow, here's how to execute the tasks:

1. Open the tasks file: `.kiro/specs/credit-evaluation-extraction/tasks.md`
2. In the Kiro sidebar, you'll see the spec listed under "Specs." Click on it to open the spec view.
3. You'll see the task list with checkboxes. Click on a task to start executing it — Kiro will read the task description, the requirements, and the design, then generate the code.
4. Kiro works in either **Autopilot** mode (executes tasks automatically) or **Supervised** mode (asks for approval before each file change). For this workshop, **Autopilot** is recommended so you can focus on reviewing the output rather than approving each tool call.
5. After each task completes, Kiro marks it done and moves to the next one.

To start, click "Run All Tasks" in the spec view, or click on Task 1 to execute it individually.

### What to Watch For

As Kiro implements each task, pay attention to:

**After Task 1 — CreditEvaluationCalculator:**
Kiro creates `LoanProcessing.Web/Services/CreditEvaluationCalculator.cs`. Verify the extracted logic matches the stored procedure by asking Kiro to generate a comparison:

> **🤖 Kiro Prompt:** "Compare the business logic in `LoanProcessing.Web/Services/CreditEvaluationCalculator.cs` with the T-SQL in `LoanProcessing.Database/StoredProcedures/sp_EvaluateCredit.sql`. Create a side-by-side comparison table showing each calculation rule (DTI ratio formula, credit score brackets, DTI brackets, risk score formula, recommendation thresholds, default interest rate) and confirm they are functionally identical. Flag any differences."

Review the comparison Kiro produces. The key things that must match exactly:
- Credit score bracket thresholds and return values (750→10, 700→20, 650→35, 600→50, <600→75)
- DTI bracket thresholds and boundary behavior (≤20→0, ≤35→10, ≤43→20, >43→30 — note ≤ not <)
- DTI formula: `((existingDebt + requestedAmount) / annualIncome) * 100`
- Recommendation strings must be exact: "Recommended for Approval", "Manual Review Required", "High Risk - Recommend Rejection"
- Default interest rate: 12.99

If anything doesn't match, the validation tests will catch it later — but it's better to spot discrepancies now.

**After Task 4 — Repository Extensions:**
Notice the new methods added to `IInterestRateRepository` and `ILoanApplicationRepository`. These push data filtering to the database (matching what the stored procedure did) rather than loading everything into memory.

**After Task 5 — CreditEvaluationService:**
This is the orchestrator. It loads data through repositories, delegates computation to the calculator, and writes results back. Notice it depends only on interfaces — you could swap the repositories for PostgreSQL implementations later without changing this class.

**After Task 7 — The Strangler Switch:**
This is the key moment. `LoanDecisionRepository.EvaluateCredit` goes from calling `sp_EvaluateCredit` to calling `CreditEvaluationService.Evaluate`. The stored procedure still exists in the database — it's just no longer called. This is the strangler pattern in action.

### Checkpoints

After Task 5: The service is complete. All new code compiles (Kiro's diagnostics will confirm). No runtime validation yet — that comes after the strangler switch.

After Task 7: Commit and push your changes. CodePipeline will deploy to EC2. Once deployed, run the validation tests from `/validation`. All tests should pass.

---

## 7. Validate the Extraction (5–10 min)

### 7.1 — Deploy and Run Validation

Commit and push your changes:

```bash
git add -A
git commit -m "Module 1: Extract sp_EvaluateCredit into CreditEvaluationService"
git push
```

Wait for CodePipeline to deploy (typically 3–5 minutes). Then navigate to `/validation` and click "Run All Tests."

All tests should pass with green status. The key tests to verify:

- **High Credit Score Risk Assessment** — credit score 780, expects RiskScore ≤ 40
- **Low Credit Score Risk Assessment** — credit score 550, expects RiskScore > 60
- **Debt-to-Income Ratio Calculation** — expects DTI > 0
- **Credit Evaluation** (in Loan Processing tests) — expects RiskScore 0–100 with recommendation

These tests exercise the exact same code paths as before — but now the logic runs in your .NET service layer instead of SQL Server.

### 7.2 — Verify the Stored Procedure is Unused

Ask Kiro to confirm the strangler switch is complete:

> **🤖 Kiro Prompt:** "Check `LoanProcessing.Web/Data/LoanDecisionRepository.cs` and confirm that the `EvaluateCredit` method no longer references `sp_EvaluateCredit` or uses `SqlCommand` with `CommandType.StoredProcedure`. Show me what it does instead."

---

## 8. Fast-Forward Remaining Extractions (5 min)

The pattern you just applied to `sp_EvaluateCredit` works for all remaining stored procedures. Rather than repeating the process 8 more times, deploy the pre-built extractions.

> **Instructor Note:** Provide participants with the branch containing all completed extractions. Participants merge or checkout this branch.

After deploying the fast-forward code, run the validation dashboard again. All tests should still pass — confirming that every stored procedure extraction maintained behavioral equivalence.

### What Was Extracted

| Stored Procedure | Extracted To | Status |
|---|---|---|
| sp_EvaluateCredit | CreditEvaluationService | ✅ Hands-on |
| sp_ProcessLoanDecision | LoanDecisionService | ✅ Fast-forward |
| sp_CalculatePaymentSchedule | PaymentScheduleService | ✅ Fast-forward |
| sp_GeneratePortfolioReport | ReportService (enhanced) | ✅ Fast-forward |
| sp_CreateCustomer | CustomerRepository (inline SQL) | ✅ Fast-forward |
| sp_UpdateCustomer | CustomerRepository (inline SQL) | ✅ Fast-forward |
| sp_GetCustomerById | CustomerRepository (inline SQL) | ✅ Fast-forward |
| sp_SearchCustomers | CustomerRepository (inline SQL) | ✅ Fast-forward |
| sp_SearchCustomersAutocomplete | CustomerRepository (inline SQL) | ✅ Fast-forward |

---

## 9. Key Takeaways

**The strangler pattern** lets you migrate business logic incrementally — one stored procedure at a time — without a big-bang rewrite. Each extraction is independently deployable and verifiable.

**The validation framework** is your safety net. It proves behavioral equivalence at every step, giving you confidence to proceed to the next module.

**The interfaces are agent-tool-shaped.** `ICreditEvaluationService.Evaluate(applicationId)` has a clear input, a deterministic output, and no side-channel dependencies. In a future module, this becomes a Lambda function, a container endpoint, or an AI agent tool with minimal refactoring.

**The database is now a pure data store.** No business logic remains in stored procedures. This makes the database migration in Module 2 dramatically simpler — it's just schema and data, no T-SQL to PL/pgSQL conversion needed.

---

## 10. What's Next

In **Module 2**, you will migrate the database from SQL Server to Aurora PostgreSQL using AWS SCT and DMS. Because all business logic now lives in the .NET service layer, the migration is a pure data operation — no stored procedure conversion required.
