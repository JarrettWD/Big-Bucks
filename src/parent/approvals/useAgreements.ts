// Each girl's onboarding and agreement (parent_agreements). The list is loaded with
// the inbox (useInbox), so the Approvals badge, the Approvals section and the
// Dashboard card always agree.

export interface KidAgreement {
  account_id: string;
  kid: string;
  is_test: boolean;
  onboarding_done: boolean;
  current_version: number;
  signed_version: number | null;
  signed_at: string | null;
  dad_signed_at: string | null;
}

export const waitingForDad = (k: KidAgreement) => k.signed_version !== null && !k.dad_signed_at;
