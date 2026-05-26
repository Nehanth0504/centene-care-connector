/**
 * @description Service class for real-time member eligibility verification
 *              against external EHR systems. Implements retry logic,
 *              structured error handling, and audit logging.
 *
 * @author      Nehanth Yarlagadda
 */
public with sharing class MemberEligibilityService {

    private static final String NAMED_CREDENTIAL = 'EHR_Integration';
    private static final String ELIGIBILITY_ENDPOINT = '/api/v1/member/eligibility';
    private static final Integer MAX_RETRIES = 3;
    private static final Integer TIMEOUT_MS = 10000;

    public static EligibilityResult verifyEligibility(Id memberId) {
        Contact member = getMemberRecord(memberId);
        EligibilityRequest req = buildRequest(member);
        return callEHRSystem(req, memberId);
    }

    public static void verifyEligibilityBulk(List<Id> memberIds) {
        MemberEligibilityBatch batch = new MemberEligibilityBatch(memberIds);
        Database.executeBatch(batch, 50);
    }

    private static Contact getMemberRecord(Id memberId) {
        return [
            SELECT Id, FirstName, LastName, Birthdate,
                   Member_ID__c, Insurance_Plan__c, Group_Number__c
            FROM Contact
            WHERE Id = :memberId
            WITH SECURITY_ENFORCED
            LIMIT 1
        ];
    }

    private static EligibilityRequest buildRequest(Contact member) {
        EligibilityRequest req = new EligibilityRequest();
        req.memberId    = member.Member_ID__c;
        req.firstName   = member.FirstName;
        req.lastName    = member.LastName;
        req.dob         = member.Birthdate != null ? member.Birthdate.format() : null;
        req.planId      = member.Insurance_Plan__c;
        req.groupNumber = member.Group_Number__c;
        return req;
    }

    private static EligibilityResult callEHRSystem(EligibilityRequest reqBody, Id memberId) {
        HttpRequest httpReq = buildHttpRequest(reqBody);
        HttpResponse httpRes;
        Integer attempt = 0;

        while (attempt < MAX_RETRIES) {
            attempt++;
            try {
                httpRes = new Http().send(httpReq);

                if (httpRes.getStatusCode() == 200) {
                    EligibilityResult result = parseResponse(httpRes.getBody());
                    IntegrationLogService.log('MemberEligibility', memberId, 'SUCCESS',
                                              httpRes.getBody(), attempt);
                    return result;
                }

                if (httpRes.getStatusCode() == 429 || httpRes.getStatusCode() >= 500) {
                    IntegrationLogService.log('MemberEligibility', memberId, 'RETRY',
                                              'HTTP ' + httpRes.getStatusCode(), attempt);
                    continue;
                }

                IntegrationLogService.log('MemberEligibility', memberId, 'ERROR',
                                          httpRes.getBody(), attempt);
                return EligibilityResult.error('HTTP ' + httpRes.getStatusCode());

            } catch (CalloutException e) {
                IntegrationLogService.log('MemberEligibility', memberId, 'EXCEPTION',
                                          e.getMessage(), attempt);
                if (attempt == MAX_RETRIES) {
                    return EligibilityResult.error(e.getMessage());
                }
            }
        }

        System.enqueueJob(new RetryQueueable(memberId, 'MemberEligibility', 1));
        return EligibilityResult.error('Max retries reached — queued for async retry.');
    }

    private static HttpRequest buildHttpRequest(EligibilityRequest reqBody) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:' + NAMED_CREDENTIAL + ELIGIBILITY_ENDPOINT);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Accept', 'application/json');
        req.setTimeout(TIMEOUT_MS);
        req.setBody(JSON.serialize(reqBody));
        return req;
    }

    private static EligibilityResult parseResponse(String responseBody) {
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(responseBody);
        EligibilityResult result   = new EligibilityResult();
        result.isEligible      = (Boolean) parsed.get('eligible');
        result.planName        = (String)  parsed.get('planName');
        result.coverageType    = (String)  parsed.get('coverageType');
        result.effectiveDate   = (String)  parsed.get('effectiveDate');
        result.terminationDate = (String)  parsed.get('terminationDate');
        result.copay           = (Decimal) parsed.get('copay');
        result.deductible      = (Decimal) parsed.get('deductible');
        result.success         = true;
        return result;
    }

    public class EligibilityRequest {
        public String memberId;
        public String firstName;
        public String lastName;
        public String dob;
        public String planId;
        public String groupNumber;
    }

    public class EligibilityResult {
        public Boolean success         = false;
        public Boolean isEligible      = false;
        public String  planName;
        public String  coverageType;
        public String  effectiveDate;
        public String  terminationDate;
        public Decimal copay;
        public Decimal deductible;
        public String  errorMessage;

        public static EligibilityResult error(String msg) {
            EligibilityResult r = new EligibilityResult();
            r.success      = false;
            r.errorMessage = msg;
            return r;
        }
    }
}
