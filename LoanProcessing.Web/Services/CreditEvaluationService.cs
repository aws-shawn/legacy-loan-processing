using System;
using LoanProcessing.Web.Data;
using LoanProcessing.Web.Models;

namespace LoanProcessing.Web.Services
{
    /// <summary>
    /// Implements credit evaluation by orchestrating repository calls and
    /// delegating computation to <see cref="CreditEvaluationCalculator"/>.
    /// Replaces the sp_EvaluateCredit stored procedure.
    /// </summary>
    public class CreditEvaluationService : ICreditEvaluationService
    {
        private readonly ILoanApplicationRepository _loanAppRepo;
        private readonly ICustomerRepository _customerRepo;
        private readonly IInterestRateRepository _rateRepo;

        /// <summary>
        /// Initializes a new instance of the <see cref="CreditEvaluationService"/> class.
        /// </summary>
        /// <param name="loanAppRepo">Repository for loan application data access.</param>
        /// <param name="customerRepo">Repository for customer data access.</param>
        /// <param name="rateRepo">Repository for interest rate data access.</param>
        public CreditEvaluationService(
            ILoanApplicationRepository loanAppRepo,
            ICustomerRepository customerRepo,
            IInterestRateRepository rateRepo)
        {
            _loanAppRepo = loanAppRepo;
            _customerRepo = customerRepo;
            _rateRepo = rateRepo;
        }

        /// <inheritdoc />
        public LoanDecision Evaluate(int applicationId)
        {
            if (applicationId <= 0)
                throw new ArgumentException("Application ID must be greater than zero.");

            var application = _loanAppRepo.GetById(applicationId);
            if (application == null)
                throw new InvalidOperationException(
                    $"Loan application with ID {applicationId} was not found.");

            var customer = _customerRepo.GetById(application.CustomerId);
            if (customer == null)
                throw new InvalidOperationException(
                    $"Customer for application {applicationId} was not found.");

            if (customer.AnnualIncome <= 0)
                throw new InvalidOperationException(
                    "Customer annual income must be greater than zero for credit evaluation.");

            decimal existingDebt = _loanAppRepo.GetApprovedAmountsByCustomer(
                customer.CustomerId, applicationId);

            decimal dtiRatio = CreditEvaluationCalculator.CalculateDtiRatio(
                existingDebt, application.RequestedAmount, customer.AnnualIncome);

            int riskScore = CreditEvaluationCalculator.CalculateRiskScore(
                customer.CreditScore, dtiRatio);

            string recommendation = CreditEvaluationCalculator.DetermineRecommendation(
                riskScore, dtiRatio);

            var rateRecord = _rateRepo.GetRateByCriteria(
                application.LoanType, customer.CreditScore,
                application.TermMonths, DateTime.Now);

            decimal interestRate = rateRecord != null
                ? rateRecord.Rate
                : CreditEvaluationCalculator.DefaultInterestRate;

            _loanAppRepo.UpdateStatusAndRate(applicationId, "UnderReview", interestRate);

            return new LoanDecision
            {
                ApplicationId = applicationId,
                RiskScore = riskScore,
                DebtToIncomeRatio = dtiRatio,
                InterestRate = interestRate,
                Comments = recommendation
            };
        }
    }
}
