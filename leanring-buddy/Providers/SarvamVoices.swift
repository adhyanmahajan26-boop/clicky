//
//  SarvamVoices.swift
//  leanring-buddy
//
//  The Bulbul v4-flash voices by language, as listed in Sarvam's Voices guide (docs.sarvam.ai, read 2026-11-02).
//  An id is <name>_<language>_<style>, and only works with bulbul:v4-flash.
//

import Foundation

extension SarvamClient {
    struct VoiceGroup: Identifiable {
        let title: String
        /// The tag in a voice's id: enhi, en, hi…
        let tag: String
        /// The value for v2.voice.sarvam.language.
        let languageSetting: String
        let speakers: [String]
        var id: String { tag }
    }

    static let v4VoiceGroups: [VoiceGroup] = [
        VoiceGroup(title: "Hinglish", tag: "enhi", languageSetting: "hinglish", speakers: [
            "shubh_enhi_ads", "shubh_enhi_banking", "shubh_enhi_companion", "ishita_enhi_companion", "ishita_enhi_customer",
            "simran_enhi_companion", "simran_enhi_customer", "sanchita_enhi_companion", "shalini_enhi_companion",
            "shalini_enhi_customer", "sunny_enhi_customer"
        ]),
        VoiceGroup(title: "English (India)", tag: "en", languageSetting: "en-IN", speakers: [
            "shubh_en_ads", "shubh_en_audiobook", "shubh_en_narration", "shubh_en_numbers", "shubh_en_recovery",
            "shubh_en_sports", "ishita_en_customer", "ishita_en_medical", "ishita_en_numbers", "ishita_en_social",
            "ishita_en_stories", "simran_en_ads", "simran_en_automobile", "simran_en_conversation", "simran_en_customer",
            "simran_en_edtech", "simran_en_narration", "simran_en_recovery", "simran_en_sales", "simran_en_therapist",
            "sanchita_en_companion", "sanchita_en_insurance", "sanchita_en_market", "sanchita_en_recovery", "sanchita_en_social",
            "shalini_en_companion", "shalini_en_customer", "ritu_en_edtech", "ritu_en_latenight", "ritu_en_medical",
            "ritu_en_reels", "neha_en_customer", "neha_en_latenight", "aditi_en_stories", "amelia_en_conversational",
            "aparna_en_companion", "aparna_en_edtech", "ashwin_en_sports", "chandrika_en_stories", "dev_en_conversational",
            "dev_en_recovery", "deven_en_conversation", "girish_en_devotional", "girish_en_documentary", "kalpit_en_edtech",
            "nachiket_en_ads", "nupur_en_kids", "ojas_en_social", "payal_en_edtech", "rohan_en_recovery",
            "roopa_en_conversational", "rustom_en_suspense", "sarang_en_narration", "shabana_en_edtech",
            "sophia_en_conversational", "sunny_en_social", "varun_en_ads", "varun_en_suspense", "zarina_en_conversation"
        ]),
        VoiceGroup(title: "Hindi", tag: "hi", languageSetting: "hi-IN", speakers: [
            "shubh_hi_ads", "shubh_hi_customer", "shubh_hi_devotional", "shubh_hi_ecomm", "shubh_hi_recovery", "ishita_hi_ads",
            "ishita_hi_banking", "ishita_hi_devotional", "ishita_hi_edtech", "ishita_hi_numbers", "ishita_hi_social",
            "simran_hi_assistant", "simran_hi_automobile", "simran_hi_conversation", "simran_hi_latenight",
            "simran_hi_narration", "simran_hi_news", "simran_hi_recovery", "simran_hi_sales", "sanchita_hi_assistant",
            "sanchita_hi_banking", "sanchita_hi_edtech", "sanchita_hi_feedback", "sanchita_hi_interview", "sanchita_hi_kyc",
            "sanchita_hi_market", "sanchita_hi_romantic", "sanchita_hi_social", "shalini_hi_companion", "shalini_hi_social",
            "ritu_hi_banking", "ritu_hi_conversation", "ritu_hi_customer", "ritu_hi_edtech", "ritu_hi_insurance", "ritu_hi_kids",
            "ritu_hi_medical", "ritu_hi_reels", "ritu_hi_sales", "ritu_hi_social", "aditya_hi_conversational", "aditya_hi_sales",
            "rahul_hi_conversational", "kavya_hi_conversational", "aarti_hi_customer", "aayan_hi_conversational",
            "advait_hi_character", "amit_hi_conversational", "anand_hi_documentary", "anand_hi_news", "aparna_hi_customer",
            "aparna_hi_kyc", "aryaman_hi_ads", "ashok_hi_character", "ashok_hi_news", "ashutosh_hi_conversational",
            "chaitra_hi_customer", "chhavi_hi_kids", "chirag_hi_social", "girish_hi_devotional", "kabir_hi_conversational",
            "kunal_hi_kids", "mahesh_hi_documentary", "manan_hi_conversational", "mani_hi_conversational", "mani_hi_devotional",
            "mohit_hi_conversational", "mukul_hi_ads", "mukul_hi_suspense", "nachiket_hi_devotional", "priya_hi_recovery",
            "ratan_hi_devotional", "ratan_hi_documentary", "ratan_hi_latenight", "ratan_hi_recovery", "ratan_hi_social",
            "ratan_hi_sports", "rehan_hi_social", "roopa_hi_companion", "roopa_hi_conversational", "roopa_hi_market",
            "roopa_hi_narration", "roopa_hi_recovery", "sarika_hi_conversation", "shilpa_hi_narration",
            "shreya_hi_conversational", "shreya_hi_news", "shruti_hi_edtech", "suchitra_hi_ecomm", "suhani_hi_social",
            "suman_hi_companion", "sumit_hi_conversational", "sunny_hi_ads", "sunny_hi_reels", "tanya_hi_narration",
            "tarun_hi_conversational", "tarun_hi_sales", "vaibhav_hi_social", "vandana_hi_ecomm", "vipul_hi_social"
        ]),
        VoiceGroup(title: "Bengali", tag: "bn", languageSetting: "bn-IN", speakers: [
            "arnab_bn_conversation", "bimal_bn_suspense", "roopa_bn_conversational"
        ]),
        VoiceGroup(title: "Gujarati", tag: "gu", languageSetting: "gu-IN", speakers: [
            "bhavik_gu_conversation", "pooja_gu_conversational", "pooja_gu_customer"
        ]),
        VoiceGroup(title: "Kannada", tag: "kn", languageSetting: "kn-IN", speakers: [
            "chaitra_kn_conversation", "chaitra_kn_narration", "chetan_kn_conversation", "suchitra_kn_narration"
        ]),
        VoiceGroup(title: "Marathi", tag: "mr", languageSetting: "mr-IN", speakers: [
            "ishita_mr_conversational", "ritu_mr_insurance", "ritu_mr_narration", "neha_mr_narration", "mrunal_mr_narration",
            "mukul_mr_stories", "nilesh_mr_conversation", "rupali_mr_stories", "soham_mr_narration"
        ]),
        VoiceGroup(title: "Punjabi", tag: "pa", languageSetting: "pa-IN", speakers: [
            "anand_pa_conversation", "anand_pa_customer", "harpreet_pa_narration", "jaspal_pa_banking"
        ]),
        VoiceGroup(title: "Tamil", tag: "ta", languageSetting: "ta-IN", speakers: [
            "aravind_ta_ads", "aravind_ta_suspense", "gokul_ta_narration", "vijay_ta_narration"
        ]),
        VoiceGroup(title: "Telugu", tag: "te", languageSetting: "te-IN", speakers: [
            "kavitha_te_conversation", "kavitha_te_narration", "pooja_te_conversation", "tarun_te_narration"
        ]),
    ]

    /// "shubh_enhi_companion" -> ("Shubh", "Companion").
    static func voiceTitle(_ speaker: String) -> (name: String, style: String) {
        let parts = speaker.split(separator: "_").map(String.init)
        guard parts.count == 3 else { return (speaker.capitalized, "") }
        return (parts[0].capitalized, parts[2].capitalized)
    }

    /// The same person's voice in another language, else that language's first voice.
    static func speaker(_ speaker: String, in languageSetting: String) -> String {
        guard let group = v4VoiceGroups.first(where: { $0.languageSetting == languageSetting }) else { return speaker }
        if group.speakers.contains(speaker) { return speaker }
        let name = speaker.split(separator: "_").first.map(String.init) ?? speaker
        return group.speakers.first { $0.hasPrefix(name + "_") } ?? group.speakers.first ?? speaker
    }
}
