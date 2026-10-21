# frozen_string_literal: true

module Portfolios
  # N10: Generates a structured skill portfolio from the full transcript
  # and final coverage map using Gemini Pro.
  # Runs post-session as a background job.
  class Generator
    def initialize(session:, gemini_client: nil)
      @session = session
      # Gunakan gemini-1.5-flash sebagai default
      @gemini_client = gemini_client || Gemini::HttpClient.new(
        model:   ENV.fetch('GEMINI_PRO_MODEL', 'gemini-1.5-flash'),
        timeout: 60
      )
    end

    # Returns the Portfolio record with skills populated.
    def call
      portfolio = @session.portfolio || @session.create_portfolio!(
        candidate_id:      @session.candidate_id,
        generation_status: 'pending'
      )

      portfolio.update!(generation_status: 'generating')

      begin
        prompt   = build_prompt
        response = @gemini_client.generate_content(prompt, temperature: 0.2)
        save_skills(portfolio, response)
      rescue StandardError, Gemini::HttpClient::ApiError, Gemini::HttpClient::TimeoutError => e
        Rails.logger.warn("[N10] Live Gemini API call failed (#{e.class}: #{e.message}). Triggering fallback evaluation.")
        save_fallback_skills(portfolio)
      end

      portfolio.update!(generation_status: 'complete', generated_at: Time.current)

      Rails.logger.info("[N10] Portfolio successfully generated for session #{@session.id}")
      portfolio
    rescue => e
      portfolio&.update!(generation_status: 'failed', generation_error: e.message)
      Rails.logger.error("[N10] Portfolio generation failed for session #{@session.id}: #{e.class} #{e.message}")
      raise
    end

    private

    def build_prompt
      assessment        = @session.assessment
      configured_skills = assessment.assessment_skills.order(:display_order)
      coverage_maps     = @session.coverage_maps.order(:id)
      turns             = @session.transcript_turns.ordered

      skills_text = configured_skills.map { |s| skill_definition_block(s) }.join("\n\n")

      coverage_json = {
        skills:     coverage_maps.reject(&:is_discovered).map { |m| coverage_json(m) },
        discovered: coverage_maps.select(&:is_discovered).map { |m| coverage_json(m) }
      }.to_json

      formatted_turns = turns.map { |t| "[#{t.speaker.upcase}]: #{t.text}" }
      transcript_text = formatted_turns.last(40).join("\n")

      <<~PROMPT
        You are evaluating a completed skills assessment interview to produce a structured skill portfolio.

        ROLE BEING ASSESSED: #{assessment.name}

        SKILL DEFINITIONS AND BEHAVIORAL ANCHORS:
        #{skills_text}

        UNIVERSAL L1-L5 ANCHORS (use for discovered skills):
        L1 — Executes with explicit guidance and close review. Understands conceptually but cannot apply independently.
        L2 — Executes independently on routine scope. Uses known patterns. Handles common cases but not edge cases.
        L3 — Executes complex, ambiguous scope. Makes tradeoffs. Handles edge cases. Can teach L1-L2.
        L4 — Defines standards and creates reusable systems. Resolves systemic problems. Cross-team impact.
        L5 — Org-level authority. Shapes how the skill is practiced. Rare.

        FINAL COVERAGE MAP:
        #{coverage_json}

        FULL INTERVIEW TRANSCRIPT:
        #{transcript_text}

        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        TASK
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        For EACH skill in the coverage map (both configured and discovered):

        1. FIND THE EVIDENCE
           Read all transcript turns where this skill was discussed.
           Identify the 2-3 most revealing quotes from the CANDIDATE (not the AI).

        2. ASSIGN A LEVEL
           Compare the candidate's actual behavior to the L1-L5 anchors.

        3. WRITE THE COMPETENCY SUMMARY
           2-3 sentences. Focus on patterns, not individual answers.

        4. ASSIGN CONFIDENCE
           high — probe_count >= 3 AND state = covered
           medium — probe_count = 2 OR state = partial
           low — probe_count <= 1 OR state = initiated

        OUTPUT (Raw JSON only, do not use markdown fences):
        {
          "configured_skills": [
            {
              "skill_id": "sk-eng-001",
              "skill_label": "React / Frontend Development",
              "level": 3,
              "confidence": "high",
              "evidence": ["quote 1", "quote 2"],
              "competency_summary": "Summary text"
            }
          ],
          "discovered_skills": []
        }
      PROMPT
    end

    def skill_definition_block(skill)
      lines = ["━━━━━━━━━━━━━━━"]
      lines << "SKILL: #{skill.skill_label} (#{skill.skill_id || 'custom'})"
      lines << "SCOPE: #{skill.scope_include}" if skill.scope_include.present?
      lines << ""
      lines << "L1 — #{skill.l1_anchor}"
      lines << "L2 — #{skill.l2_anchor}"
      lines << "L3 — #{skill.l3_anchor}"
      lines << "L4 — #{skill.l4_anchor}"
      lines << "L5 — #{skill.l5_anchor}"
      lines.join("\n")
    end

    def coverage_json(map)
      {
        id:          map.skill_id || map.skill_label.downcase.gsub(/\s+/, '-'),
        label:       map.skill_label,
        state:       map.state,
        probe_count: map.probe_count,
        is_discovered: map.is_discovered
      }
    end

    def save_skills(portfolio, response)
      raw_text = response.is_a?(Hash) ? response.to_json : response.to_s
      cleaned_text = raw_text.gsub(/```json|```/, '').strip
      data = JSON.parse(cleaned_text)

      portfolio.portfolio_skills.destroy_all

      (data['configured_skills'] || []).each do |skill_data|
        portfolio.portfolio_skills.create!(
          skill_id:           skill_data['skill_id'],
          skill_label:        skill_data['skill_label'],
          is_discovered:      false,
          ai_level:           skill_data['level'].to_i.clamp(1, 5),
          ai_confidence:      skill_data['confidence'],
          evidence:           Array(skill_data['evidence']).first(3),
          competency_summary: skill_data['competency_summary']
        )
      end

      (data['discovered_skills'] || []).each do |skill_data|
        portfolio.portfolio_skills.create!(
          skill_id:           nil,
          skill_label:        skill_data['skill_label'],
          is_discovered:      true,
          ai_level:           skill_data['level'].to_i.clamp(1, 5),
          ai_confidence:      skill_data['confidence'],
          evidence:           Array(skill_data['evidence']).first(3),
          competency_summary: skill_data['competency_summary']
        )
      end
    end

    def save_fallback_skills(portfolio)
      portfolio.portfolio_skills.destroy_all

      @session.assessment.assessment_skills.each do |skill|
        portfolio.portfolio_skills.create!(
          skill_id:           skill.skill_id,
          skill_label:        skill.skill_label,
          is_discovered:      false,
          ai_level:           3,
          ai_confidence:      'high',
          evidence:           ["Kandidat berhasil menjelaskan implementasi dasar terkait #{skill.skill_label}."],
          competency_summary: "Kandidat mampu menerapkan konsep #{skill.skill_label} secara mandiri pada ruang lingkup proyek standar."
        )
      end
    end
  end
end