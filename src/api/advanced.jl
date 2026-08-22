"""
Advanced, research-facing API facade.

The root exports remain backward-compatible during the consolidation phase.
New code that depends on profiling, numerical-policy, or typed-capability
experiments can opt into this explicit namespace while the stable root API is
reviewed for a future release.
"""
module Advanced

import ..NLPDiagnostics

const ProfileCase = NLPDiagnostics.ProfileCase
const ProfileAggregate = NLPDiagnostics.ProfileAggregate
const ProfileResult = NLPDiagnostics.ProfileResult
const RankPolicy = NLPDiagnostics.RankPolicy
const UnavailableReason = NLPDiagnostics.UnavailableReason

const profile_case = NLPDiagnostics.profile_case
const profile_case_repeated = NLPDiagnostics.profile_case_repeated
const profile_cases_repeated = NLPDiagnostics.profile_cases_repeated
const profile_result_data = NLPDiagnostics.profile_result_data
const profile_aggregate_data = NLPDiagnostics.profile_aggregate_data
const jacobian_rank_estimate = NLPDiagnostics.jacobian_rank_estimate
const sparse_qr_rank_estimate = NLPDiagnostics.sparse_qr_rank_estimate
const unavailable_reason = NLPDiagnostics.unavailable_reason
const unavailable_reason_data = NLPDiagnostics.unavailable_reason_data

export ProfileCase
export ProfileAggregate
export ProfileResult
export RankPolicy
export UnavailableReason
export profile_case
export profile_case_repeated
export profile_cases_repeated
export profile_result_data
export profile_aggregate_data
export jacobian_rank_estimate
export sparse_qr_rank_estimate
export unavailable_reason
export unavailable_reason_data

end
