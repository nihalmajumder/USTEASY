/*****************************************
* File: INT_InteractionProcessor
* Author: Sierra-Cedar
* Description: Processes new Interaction__c records by inserting/converting Leads, upserting Opportunities,
* updating Contacts, upserting Affiliations, and upserting CampaignMembers
******************************************/
public class INT_InteractionProcessor {

    private List<Interaction__c> dupeInteractions = new List<Interaction__c>();
    private List<Lead> leadsToDelete = new List<Lead>();
    private List<Opportunity> opportunitiesToUpsert = new List<Opportunity>();
    private Map<Id, Lead> interactionIdToLead = new Map<Id, Lead>();
    private Map<Id, Interaction__c> interactionMap = new Map<Id, Interaction__c>();
    private Map<Id, Interaction__c> leadIdToInteractionMap = new Map<Id, Interaction__c>();
    private Set<Id> leadIds = new Set<Id>();

    private INT_InteractionMappingService intMappingService {
        get {
            if (intMappingService == null) {
                intMappingService = new INT_InteractionMappingService();
            }

            return intMappingService;
        }

        set;
    }

    private Map<Id, Id> campaignIdMap {
        get {
            if (campaignIdMap == null) {
                campaignIdMap = new Map<Id, Id>();
                Set<String> referenceIds = new Set<String>();

                for (SObject interaction : Trigger.new) {
                    if (interaction.get('Campaign_Key__c') != null) {
                        referenceIds.add(String.valueOf(interaction.get('Campaign_Key__c')));
                    }

                    if (interaction.get('Additional_Campaign_Key__c') != null) {
                        referenceIds.add(String.valueOf(interaction.get('Additional_Campaign_Key__c')));
                    }
                }

                for (Campaign aCampaign : [
                        SELECT Id, Campaign_Key__c
                        FROM Campaign
                        WHERE (Campaign_Key__c IN :referenceIds OR Id IN :referenceIds)
                ]) {
                    campaignIdMap.put(aCampaign.Campaign_Key__c, aCampaign.Id);
                }
            }

            return campaignIdMap;
        }

        set;
    }

    private Map<String, CampaignMember> campaignMemberMap {
        get {
            if (campaignMemberMap == null) {
                campaignMemberMap = new Map<String, CampaignMember>();

                // Loop through current Campaign Members and build campaignMemberMap
                for (CampaignMember cm : [
                        SELECT Status, ContactId, LeadId, CampaignId, Campaign.Campaign_Key__c
                        FROM CampaignMember
                        WHERE LeadId IN :leadIds
                ]) {
                    if (!String.isEmpty(cm.Campaign.Campaign_Key__c)) {
                        campaignMemberMap.put(String.valueOf(cm.LeadId + '.' + cm.Campaign.Campaign_Key__c), cm);
                    } else {
                        campaignMemberMap.put(String.valueOf(cm.LeadId + '.' + cm.CampaignId), cm);
                    }
                }
            }

            return campaignMemberMap;
        }

        set;
    }

    // Grab Lead conversion master label.
    private LeadStatus convertStatus {
        get {
            if (convertStatus == null) {
                convertStatus = [SELECT Id, MasterLabel FROM LeadStatus WHERE IsConverted = true LIMIT 1];
            }

            return convertStatus;
        }

        set;
    }

    /**
     * @description Inserts Leads only from new Interaction__c records.
     * @param interactionsToProcess, the List of new Interaction__c objects to process.
     */
    public void processLeads(List<Interaction__c> newInteractions) {
        // Run duplicate pre-processing
        List<Interaction__c> interactionsToProcess = duplicatePreProcessing(newInteractions);

        // Set up Interaction Map for reference during processing.
        interactionMap = new Map<Id, Interaction__c>(interactionsToProcess);

        // Insert Leads from the new Interaction records.
        List<Database.LeadConvert> newLeads = insertLeadsFromInteractions(interactionsToProcess);

        // Apply Interaction Mappings to all Leads
        List<Lead> leadsToUpdate = new List<Lead>();
        for (String leadId : leadIdToInteractionMap.keySet()) {
            Lead leadToUpdate = new Lead(Id = leadId);
            intMappingService.applyDataToSObject(leadIdToInteractionMap.get(leadId), leadToUpdate);
            leadsToUpdate.add(leadToUpdate);
        }

        // Update Leads with data from the mapping service.
        if (leadsToUpdate.size() > 0) {
            logPossibleErrors(Database.update(leadsToUpdate, false));
        }

        // Create CampaignMembers to upsert from the Leads inserted if they have the proper Campaign Keys
        List<CampaignMember> campaignMembersToUpsert = createCampaignMembersFromLeads();

        // Upsert Campaign Members from Leads
        if (campaignMembersToUpsert.size() > 0) {
            logPossibleErrors(Database.upsert(campaignMembersToUpsert, CampaignMember.Campaign_Member_Key__c, false));
        }

        // Finally set Interaction_Status__c after processing and flag if errored.
        for (Interaction__c interaction : interactionsToProcess) {
            interaction.Interaction_Status__c = (!String.isEmpty(interaction.Audit_Reason__c)) ? 'Audit Required' : 'Imported';
        }

        // Add any duplicates found and update the Interactions with new Status from processing.
        interactionsToProcess.addAll(dupeInteractions);
        logPossibleErrors(Database.update(interactionsToProcess, false));
    }

    /**
     * @description Main method for processing new Interaction__c records.
     * @param interactionsToProcess, the List of new Interaction__c objects to process.
     */
    public void processInteractions(List<Interaction__c> newInteractions) {
        List<Contact> contactsToUpdate = new List<Contact>();
        List<SObject> affiliationsToUpsert = new List<SObject>();

        // Run duplicate pre-processing
        List<Interaction__c> interactionsToProcess = duplicatePreProcessing(newInteractions);

        // Set up Interaction Map for reference during processing.
        interactionMap = new Map<Id, Interaction__c>(interactionsToProcess);

        // Create Leads from new Interactions records.
        List<Database.LeadConvert> newLeads = insertLeadsFromInteractions(interactionsToProcess);

        // Create CampaignMembers to upsert from the Leads inserted if they have the proper Campaign Keys
        List<CampaignMember> campaignMembersToUpsert = createCampaignMembersFromLeads();

        // Upsert Campaign Members from Leads
        if (campaignMembersToUpsert.size() > 0) {
            logPossibleErrors(Database.upsert(campaignMembersToUpsert, CampaignMember.Campaign_Member_Key__c, false));
        }

        // Convert Leads
        convertLeads(newLeads);

        // Upsert associated Opportunities using Opportunity_Key__c as the lookup Id.
        if (opportunitiesToUpsert.size() > 0) {
            logPossibleErrors(Database.upsert(opportunitiesToUpsert, Opportunity.Opportunity_Key__c, false));
        }

        Map<String, Schema.SObjectType> gd = Schema.getGlobalDescribe();
        Boolean heda = gd.containsKey('hed__Affiliation__c') && gd.get('hed__Affiliation__c').getDescribe().fields.getMap().containsKey('Upsert_Key__c');

        Set<String> affiliationUpsertKeys = new Set<String>();
        for (Interaction__c interaction : interactionsToProcess) {
            if (heda && interaction.get('Affiliation_Key__c') != null) {
                affiliationUpsertKeys.add(interaction.Contact__c + interaction.Affiliation_Key__c);
            }
        }

        Map<String, SObject> affiliationMap = new Map<String, SObject>();
        if (heda) {
            for (SObject so:Database.query('SELECT Id, Upsert_Key__c FROM hed__Affiliation__c WHERE Upsert_Key__c IN :affiliationUpsertKeys')) {
                affiliationMap.put((String)so.get('Upsert_Key__c'), so);
            }
        }

        // Finally, associate referenced Opportunity and set Interaction_Status__c after processing and flag if errored.
        for (Interaction__c interaction : interactionsToProcess) {
            if (!String.isEmpty(interaction.Contact__c)) {
                Contact newCont = new Contact(Id = interaction.Contact__c);
                intMappingService.applyDataToSObject(interaction, newCont);
                contactsToUpdate.add(newCont);
            }

            if (heda && interaction.get('Affiliation_Key__c') != null) {
                affiliationsToUpsert.add(createUpsertAffilFromInteraction(interaction, affiliationMap));
            }

            // Set the new referenced Opportunity's Id on the Interaction__c lookup field.
            if (interaction.Opportunity__r != null) {
                interaction.Opportunity__c = interaction.Opportunity__r.Id;
                interaction.Opportunity__r = null;
            }

            // Check for Interactions that have Opportunity Keys, but no Opportunity associated, flag them.
            if ((interaction.Opportunity_Key__c != null) && (interaction.Opportunity__c == null)) {
                String error = ' Reason: Interaction has an Opportunity Key, but could not find ' +
                        'associated Opportunity in the system. Please verify that the Opportunity Key is valid.';
                interaction.Audit_Reason__c += error;
            }

            interaction.Interaction_Status__c = (!String.isEmpty(interaction.Audit_Reason__c)) ? 'Audit Required' : 'Imported';
        }

        // Update Contacts
        if (contactsToUpdate.size() > 0) {
            logPossibleErrors(Database.update(contactsToUpdate, false));
        }

        // Upsert Affiliations using the Upsert_Key__c
        List<SObject> affiliationsToInsert = new List<SObject>();
        List<SObject> affiliationsToUpdate = new List<SObject>();
        for (SObject so:affiliationsToUpsert) {
            if (so.Id == null) {
                affiliationsToInsert.add(so);
            } else {
                affiliationsToUpdate.add(so);
            }
        }
        logPossibleErrors(Database.insert(affiliationsToUpsert, false));
        logPossibleErrors(Database.update(affiliationsToUpsert, false));

        // Upsert CampaignMembers
        if (campaignMembersToUpsert.size() > 0) {
            logPossibleErrors(Database.upsert(campaignMembersToUpsert, CampaignMember.Campaign_Member_Key__c, false));
        }

        // Add any duplicates found and update the Interactions with new Status from processing.
        interactionsToProcess.addAll(dupeInteractions);
        logPossibleErrors(Database.update(interactionsToProcess, false));

        // Cleanup converted Leads.
        if (leadsToDelete.size() > 0) {
            Database.delete(leadsToDelete, false);
        }
    }

    /**
     * @description Does basic pre-processing for duplicates of the Interactions in the import. If it finds a possible
     * duplicate, it removes it from the import and flags it for future processing.
     * @param interactions, the List of new Interaction__c records.
     * @return the List of filtered Interaction__c records for processing.
     */
    private List<Interaction__c> duplicatePreProcessing(List<Interaction__c> interactions) {
        // If the custom setting is turned off, return the List and do not run any pre-processing for duplicates.
        if (Interactions_PreProcessing__c.getAll().values() != null) {
            for (Interactions_PreProcessing__c ipp : Interactions_PreProcessing__c.getAll().values()) {
                if (!ipp.Active__c) return interactions;
            }
        }

        Map<String, Interaction__c> filteredMap = new Map<String, Interaction__c>();

        for (Interaction__c interaction : interactions) {
            String filterKey = interaction.First_Name__c + interaction.Last_Name__c + interaction.Email__c;
            if (!filteredMap.containsKey(filterKey)) {
                filteredMap.put(filterKey, interaction);
            } else {
                interaction.Interaction_Status__c = 'Audit Required';
                String error = ' Reason: this Interaction was not processed because it is a possible ' +
                        'duplicate of - ' + filteredMap.get(filterKey).Id + ': ' + filteredMap.get(filterKey).First_Name__c +
                        ' ' + filteredMap.get(filterKey).Last_Name__c + ' ' + filteredMap.get(filterKey).Email__c;
                interaction.Audit_Reason__c = error;
                dupeInteractions.add(interaction);
            }
        }

        return filteredMap.values();
    }

    /**
     * @description Kick off the Interactions process by creating Leads to convert.
     * @param interactions, the list of new Interaction__c objects to insert Leads from.
     * @return leadConverts, the Lead Convert records to convert.
     */
    private List<Database.LeadConvert> insertLeadsFromInteractions(List<Interaction__c> interactions) {

        List<Database.LeadConvert> leadConverts = new List<Database.LeadConvert>();
        List<Contact> newCons = new List<Contact>();

        // Associate Campaigns and create new Leads from Interaction records.
        for (Interaction__c interaction : interactions) {
            // Set Campaign__c on Interaction
            if (!String.isEmpty(interaction.Campaign_Key__c)
                    && campaignIdMap.containsKey(interaction.Campaign_Key__c)
                    ) {
                interaction.Campaign__c = campaignIdMap.get(interaction.Campaign_Key__c);
            }

            // Set Additional_Campaign__c on Interaction.
            if (!String.isEmpty(interaction.Additional_Campaign_Key__c)
                    && campaignIdMap.containsKey(interaction.Additional_Campaign_Key__c)
                    ) {
                interaction.Additional_Campaign__c = campaignIdMap.get(interaction.Additional_Campaign_Key__c);
            }

            Lead newLead = new Lead(
                    FirstName = interaction.First_Name__c,
                    LastName = interaction.Last_Name__c,
                    Company = interaction.Last_Name__c + ', ' + interaction.First_Name__c
            );

            interactionIdToLead.put(interaction.Id, newLead);
            intMappingService.applyDataToSObject(interaction, newLead);

            Contact newCon = new Contact(
                    FirstName = newLead.FirstName,
                    LastName = newLead.LastName,
                    MailingStreet = newLead.Street,
                    MailingCity = newLead.City,
                    MailingState = newLead.State,
                    MailingCountry = newLead.Country,
                    MailingPostalCode = newLead.PostalCode,
                    Email = newLead.Email,
                    Fax = newLead.Fax,
                    MobilePhone = newLead.MobilePhone,
                    Phone = newLead.Phone,
                    Title = newLead.Title
            );

            intMappingService.applyDataToSObject(interaction, newCon);
            newCons.add(newCon);
        }

        // Break list into list of lists with maximum size of 50 because of duplicate find limits
        List<List<Contact>> newConsList = new List<List<Contact>>{new List<Contact>()};
        for (Contact c:newCons) {
            if (newConsList[newConsList.size() - 1].size() == 50)
                newConsList.add(new List<Contact>());
            newConsList[newConsList.size() - 1].add(c);
        }

        // Look for duplicates and add ID if one exists
        Integer interactionsIndex = 0;
        for (List<Contact> cons:newConsList) {

            List<Datacloud.FindDuplicatesResult> results = Datacloud.FindDuplicates.findDuplicates(cons);

            for (Integer i = 0; i < cons.size(); i++) {
                if (interactions[interactionsIndex].Lead_Only__c == false) {
                    for (Datacloud.DuplicateResult result:results[i].getDuplicateResults()) {
                        for (Datacloud.MatchResult matchResult:result.getMatchResults()) {
                            if (matchResult.getEntityType() == 'Contact' && !matchResult.getMatchRecords().isEmpty()) {
                                interactions[interactionsIndex].Contact__c = matchResult.getMatchRecords()[0].getRecord().Id;
                                break;
                            }
                        }

                        if (interactions[interactionsIndex].Contact__c != null)
                            break;
                    }
                }

                interactionsIndex++;
            }
        }

        leadConverts.addAll(insertLeads(interactionIdToLead.values()));

        return leadConverts;
    }

    /**
     * @description Inserts a collection of Leads. If there are failures, log issues to Interaction Audit Status.
     * @param leads, a List of Lead objects to insert.
     * @return leadsToConvert, a List of Database.LeadConvert records to convert.
     */
    private List<Database.LeadConvert> insertLeads(List<Lead> leadsToInsert) {

        // Break list into list of lists with maximum size of 50 because of duplicate find limits
        List<List<Lead>> leadsToInsertList = new List<List<Lead>>{new List<Lead>()};
        for (Lead l:leadsToInsert) {
            if (leadsToInsertList[leadsToInsertList.size() - 1].size() == 50)
                leadsToInsertList.add(new List<Lead>());
            leadsToInsertList[leadsToInsertList.size() - 1].add(l);
        }

        // Look for duplicates and add ID if one exists
        Set<Id> existingLeadIds = new Set<Id>();
        for (List<Lead> leads:leadsToInsertList) {

            List<Datacloud.FindDuplicatesResult> results = Datacloud.FindDuplicates.findDuplicates(leads);

            for (Integer i = 0; i < leads.size(); i++) {
                for (Datacloud.DuplicateResult result:results[i].getDuplicateResults()) {
                    for (Datacloud.MatchResult matchResult:result.getMatchResults()) {
                        if (!matchResult.getMatchRecords().isEmpty()) {
                            leads[i].Id = matchResult.getMatchRecords()[0].getRecord().Id;
                            existingLeadIds.add(leads[i].Id);
                            break;
                        }
                    }
                    if (leads[i].Id != null)
                        break;
                }
            }
        }

        Database.UpsertResult[] srlist = Database.upsert(leadsToInsert, false); // Insert Leads
        List<Database.LeadConvert> leadsToConvert = new List<Database.LeadConvert>();
        Map<Id, Database.UpsertResult> leadResultMap = new Map<Id, Database.UpsertResult>();

        for (Database.UpsertResult sr : srlist) leadResultMap.put(sr.getId(), sr);

        for (Id intearctionId : interactionIdToLead.keySet()) {
            if (leadResultMap.containsKey(interactionIdToLead.get(intearctionId).Id)) {
                Database.UpsertResult sr = leadResultMap.get(interactionIdToLead.get(intearctionId).Id);
                Id leadId = interactionIdToLead.get(intearctionId).Id;
                Interaction__c interaction = interactionMap.get(intearctionId);

                if (sr.isSuccess()) { // Check if insert was a success

                    leadIds.add(sr.getId());
                    interaction.Lead__c = leadId;
                    leadIdToInteractionMap.put(interaction.Lead__c, interaction);

                    // On success, prepare to convert inserted lead.
                    if (interaction.Lead_Only__c == false) {

                        leadsToConvert.add(createLeadConvert(interactionMap.get(intearctionId), leadId, true));

                        if (!existingLeadIds.contains(leadId))
                            leadsToDelete.add(new Lead(Id = leadId)); // Newly created leads will be deleted
                    }
                } else {
                    // If there are errors, loop through them and either log the error on the Interaction.
                    for (Database.Error error : sr.getErrors()) {
                        interaction.Audit_Reason__c += ' Reason: Error during Lead insert - ' + error.getMessage() + '.';
                        System.debug('Error during Lead insert - ' + error.getMessage() + '.');
                    }
                }
            }
        }

        return leadsToConvert;
    }

    /**
     * @description Creates a Database.LeadConvert Object from supplied Interaction record.
     * @param interaction, the Interaction__c to create Database.LeadConvert from.
     * @param leadId, the Id of the Lead to convert.
     * @param createOppty, whether or not to create an Opportunity from the Database.LeadConvert.
     */
    private Database.LeadConvert createLeadConvert(Interaction__c interaction, String leadId, Boolean createOppty) {
        // Prepare to convert matching lead
        leadIdToInteractionMap.put(leadId, interaction);
        Database.LeadConvert leadConvert = new Database.LeadConvert();
        leadConvert.setLeadId(leadId);
        leadConvert.setConvertedStatus(convertStatus.MasterLabel);
        leadConvert.setContactId(interaction.Contact__c);

        Id accountId;
        if (interaction.Contact_Account_ID__c != null) {
            accountId = interaction.Contact_Account_ID__c;
        } else if (ApexPages.currentPage() != null && ApexPages.currentPage().getUrl() != null && ApexPages.currentPage().getUrl().contains('ApplicationRegistration') && Network.getNetworkId() != null && !Test.isRunningTest()) {
            accountId = [SELECT Id, AccountId FROM NetworkSelfRegistration WHERE NetworkId = :Network.getNetworkId() LIMIT 1].AccountId;
        }

        leadConvert.setAccountId(accountId);
        leadConvert.setDoNotCreateOpportunity(createOppty);

        return leadConvert;
    }

    /**
     * @description Converts Leads, returns any Database.LeadConvert errors found to be reconverted later.
     * @param leadsToConvert, the List of Lead records to convert.
     * @return leadsToReconvert, a List of possible Database.LeadConvert error records to try and reconvert.
     */
    private void convertLeads(List<Database.LeadConvert> leadsToConvert) {

        // Get set of all lead converts where contact has been specified but not account
        Set<Id> contactIdsMissingAccount = new Set<Id>();
        for (Database.LeadConvert lc:leadsToConvert) {
            if (lc.getContactId() != null && lc.getAccountId() == null) {
                contactIdsMissingAccount.add(lc.getContactId());
            }
        }

        // Query for contact's account and set it on lead convert
        if (!contactIdsMissingAccount.isEmpty()) {
            Map<Id, Contact> contacts = new Map<Id, Contact>([SELECT Id, AccountId FROM Contact WHERE Id IN :contactIdsMissingAccount]);
            for (Database.LeadConvert lc:leadsToConvert) {
                if (lc.getContactId() != null && lc.getAccountId() == null && contacts.containsKey(lc.getContactId())) {
                    lc.setAccountId(contacts.get(lc.getContactId()).AccountId);
                }
            }
        }

        Database.LeadConvertResult[] leadConvertResults = Database.convertLead(leadsToConvert, false); // Convert Leads

        for (Database.LeadConvertResult lcr : leadConvertResults) {
            Interaction__c interaction = (leadIdToInteractionMap.containsKey(lcr.getLeadId())) ? leadIdToInteractionMap.get(lcr.getLeadId()) : null;

            if (lcr.isSuccess()) {
                // Add Contact Id to set to be updated from its Interaction record.
                interaction.Contact__c = lcr.getContactId();

                // Create new Opportunity for upsert if Opportunity Key is populated.
                if (!String.isEmpty(interaction.Opportunity_Key__c)) {
                    Opportunity newOppty = new Opportunity(
                            CloseDate = System.today(),
                            StageName = interaction.Opportunity_Stage__c,
                            Opportunity_Key__c = lcr.getContactId() + interaction.Opportunity_Key__c,
                            AccountId = lcr.getAccountId()
                    );
                    intMappingService.applyDataToSObject(interaction, newOppty);
                    interaction.Opportunity__r = newOppty;
                    opportunitiesToUpsert.add(newOppty);
                }
            } else {
                // Find all of the errors for Lead conversion.
                for (Database.Error error : lcr.getErrors()) {
                    interaction.Audit_Reason__c += ' Reason: Error during Lead conversion - ' + error.getMessage() + '.';
                    System.debug('Error during Lead conversion - ' + error.getMessage() + '.');
                }
            }
        }
    }

    /**
     * @description Creates a new Affiliation record for upsert from the data on the Interaction__c. provided.
     * @param interaction, the Interaction__c record to copy data from.
     * @return newAffil, the Affiliation__c record for upsert.
     */
    private SObject createUpsertAffilFromInteraction(Interaction__c interaction, Map<String, SObject> existingAffiliations) {

        String upsertKey = interaction.Contact__c + interaction.Affiliation_Key__c;

        SObject newAffil;
        if (existingAffiliations.containsKey(upsertKey)) {
            newAffil = existingAffiliations.get(upsertKey);
        } else {
            newAffil = Schema.getGlobalDescribe().get('hed__Affiliation__c').newSObject();
        }

        newAffil.put('hed__Status__c', 'Current');
        newAffil.put('hed__Role__c', interaction.Affiliation_Role__c);
        newAffil.put('hed__Primary__c', interaction.Primary_Affiliation__c);
        newAffil.put('hed__Contact__c', interaction.Contact__c);
        newAffil.put('hed__Account__c', interaction.Affiliated_Account__c);

        intMappingService.applyDataToSObject(interaction, newAffil);
        newAffil.put('Upsert_Key__c', upsertKey);

        return newAffil;
    }

    /**
     * @description Creates a List of CampaignMember records to upsert from the Leads that have been inserted.
     * @return campaignMembersToUpsert, the List of CampaignMember records to upsert.
     */
    private List<CampaignMember> createCampaignMembersFromLeads() {
        List<CampaignMember> campaignMembersToUpsert = new List<CampaignMember>();

        for (String leadId : leadIdToInteractionMap.keySet()) {
            if (!String.isEmpty(leadIdToInteractionMap.get(leadId).Campaign_Member_Status__c)
                    && !String.isEmpty(leadIdToInteractionMap.get(leadId).Campaign_Key__c)
                    && !String.isEmpty(leadIdToInteractionMap.get(leadId).Lead__c)
                    ) {
                campaignMembersToUpsert.add(createUpsertCMFromInteraction(leadIdToInteractionMap.get(leadId), false));
            }

            // Create a CampaignMember to Upsert for the Additional_Campaign_Key__c if it is populated.
            if (!String.isEmpty(leadIdToInteractionMap.get(leadId).Additional_Campaign_Key__c)
                    && !String.isEmpty(leadIdToInteractionMap.get(leadId).Additional_Campaign_Member_Status__c)
                    && !String.isEmpty(leadIdToInteractionMap.get(leadId).Lead__c)
                    ) {
                campaignMembersToUpsert.add(createUpsertCMFromInteraction(leadIdToInteractionMap.get(leadId), true));
            }
        }

        return campaignMembersToUpsert;
    }

    /**
     * @description Creates a new CampaignMember record for upsert from the data on the Interaction__c provided.
     * @param interaction, the Interaction__c record to copy data from.
     * @param additionalCampaign, a bool telling the method to use Campaign or Additional Campaign fields on the Interaction__c.
     * @return memberToUpsert, the CampaignMember to upsert.
     */
    private CampaignMember createUpsertCMFromInteraction(Interaction__c interaction, Boolean additionalCampaign) {
        CampaignMember memberToUpsert;
        String campaignKey = (!additionalCampaign) ? interaction.Campaign_Key__c : interaction.Additional_Campaign_Key__c;
        String campaignMemberStatus = (!additionalCampaign) ? interaction.Campaign_Member_Status__c : interaction.Additional_Campaign_Member_Status__c;
        String campaignMemberKey = String.valueOf(interaction.Lead__c + '.' + campaignKey);

        if (campaignMemberMap.containskey(campaignMemberKey)) {
            memberToUpsert = campaignMemberMap.get(campaignMemberKey);
            memberToUpsert.Campaign_Member_Key__c = interaction.Lead__c + '.' + campaignIdMap.get(campaignKey);
        } else {
            memberToUpsert = new CampaignMember(
                    LeadId = interaction.Lead__c,
                    CampaignId = campaignIdMap.get(campaignKey),
                    Campaign_Member_Key__c = interaction.Lead__c + '.' + campaignIdMap.get(campaignKey)
            );
        }

        memberToUpsert.Status = campaignMemberStatus;
        intMappingService.applyDataToSObject(interaction, memberToUpsert);

        return memberToUpsert;
    }

    /**
     * @description Debugs SaveResult errors if they happen.
     * @param saveResults, the Database.SaveResult List to check.
     */
    private static void logPossibleErrors(Database.SaveResult[] saveResults) {
        for (Database.SaveResult result : saveResults) {
            if (!result.isSuccess()) {
                System.debug('Save Result Error: ' + result.getErrors() + ' ' + result.getId());
            }
        }
    }

    /**
     * @description Debugs UpsertResult errors if they happen.
     * @param saveResults, the Database.UpsertResult List to check.
     */
    private static void logPossibleErrors(Database.UpsertResult[] saveResults) {
        for (Database.UpsertResult result : saveResults) {
            if (!result.isSuccess()) {
                System.debug('Upsert Error: ' + result.getErrors() + ' ' + result.getId());
            }
        }
    }
}