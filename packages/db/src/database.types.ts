export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  public: {
    Tables: {
      attendance: {
        Row: {
          center_id: string
          comment: string | null
          counts_absence: boolean
          created_at: string
          deducted: boolean
          id: string
          lesson_id: string
          marked_at: string
          marked_by: string | null
          paid_teacher_id: string
          pays_teacher: boolean
          price_tiyin: number
          status_id: string
          student_id: string
          subscription_id: string | null
          updated_at: string
        }
        Insert: {
          center_id?: string
          comment?: string | null
          counts_absence?: boolean
          created_at?: string
          deducted?: boolean
          id?: string
          lesson_id: string
          marked_at?: string
          marked_by?: string | null
          paid_teacher_id: string
          pays_teacher: boolean
          price_tiyin?: number
          status_id: string
          student_id: string
          subscription_id?: string | null
          updated_at?: string
        }
        Update: {
          center_id?: string
          comment?: string | null
          counts_absence?: boolean
          created_at?: string
          deducted?: boolean
          id?: string
          lesson_id?: string
          marked_at?: string
          marked_by?: string | null
          paid_teacher_id?: string
          pays_teacher?: boolean
          price_tiyin?: number
          status_id?: string
          student_id?: string
          subscription_id?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "attendance_center_id_fkey"
            columns: ["center_id"]
            isOneToOne: false
            referencedRelation: "centers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "attendance_lesson_fk"
            columns: ["lesson_id", "center_id"]
            isOneToOne: false
            referencedRelation: "lessons"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "attendance_paid_teacher_fk"
            columns: ["paid_teacher_id", "center_id"]
            isOneToOne: false
            referencedRelation: "teachers"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "attendance_status_fk"
            columns: ["status_id", "center_id"]
            isOneToOne: false
            referencedRelation: "attendance_statuses"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "attendance_student_fk"
            columns: ["student_id", "center_id"]
            isOneToOne: false
            referencedRelation: "students"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "attendance_student_fk"
            columns: ["student_id", "center_id"]
            isOneToOne: false
            referencedRelation: "students_teacher_view"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "attendance_subscription_fk"
            columns: ["subscription_id", "center_id"]
            isOneToOne: false
            referencedRelation: "subscriptions"
            referencedColumns: ["id", "center_id"]
          },
        ]
      }
      attendance_statuses: {
        Row: {
          center_id: string
          code: string
          color: string
          counts_absence: boolean
          created_at: string
          created_by: string | null
          deducts_lesson: boolean
          deleted_at: string | null
          id: string
          is_default: boolean
          name: string
          notify_parent: boolean
          pays_teacher: boolean
          sort: number
          updated_at: string
        }
        Insert: {
          center_id?: string
          code: string
          color?: string
          counts_absence?: boolean
          created_at?: string
          created_by?: string | null
          deducts_lesson?: boolean
          deleted_at?: string | null
          id?: string
          is_default?: boolean
          name: string
          notify_parent?: boolean
          pays_teacher?: boolean
          sort?: number
          updated_at?: string
        }
        Update: {
          center_id?: string
          code?: string
          color?: string
          counts_absence?: boolean
          created_at?: string
          created_by?: string | null
          deducts_lesson?: boolean
          deleted_at?: string | null
          id?: string
          is_default?: boolean
          name?: string
          notify_parent?: boolean
          pays_teacher?: boolean
          sort?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "attendance_statuses_center_id_fkey"
            columns: ["center_id"]
            isOneToOne: false
            referencedRelation: "centers"
            referencedColumns: ["id"]
          },
        ]
      }
      audit_log: {
        Row: {
          action: string
          at: string
          center_id: string | null
          id: number
          new_data: Json | null
          old_data: Json | null
          row_id: string | null
          table_name: string
          user_id: string | null
        }
        Insert: {
          action: string
          at?: string
          center_id?: string | null
          id?: number
          new_data?: Json | null
          old_data?: Json | null
          row_id?: string | null
          table_name: string
          user_id?: string | null
        }
        Update: {
          action?: string
          at?: string
          center_id?: string | null
          id?: number
          new_data?: Json | null
          old_data?: Json | null
          row_id?: string | null
          table_name?: string
          user_id?: string | null
        }
        Relationships: []
      }
      center_digest_runs: {
        Row: {
          center_id: string
          digest_on: string
          sent_at: string
        }
        Insert: {
          center_id: string
          digest_on: string
          sent_at?: string
        }
        Update: {
          center_id?: string
          digest_on?: string
          sent_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "center_digest_runs_center_id_fkey"
            columns: ["center_id"]
            isOneToOne: false
            referencedRelation: "centers"
            referencedColumns: ["id"]
          },
        ]
      }
      centers: {
        Row: {
          created_at: string
          deleted_at: string | null
          id: string
          name: string
          plan: string
          settings: Json
          slug: string
          subscription_until: string | null
          trial_ends_at: string | null
          updated_at: string
        }
        Insert: {
          created_at?: string
          deleted_at?: string | null
          id?: string
          name: string
          plan?: string
          settings?: Json
          slug: string
          subscription_until?: string | null
          trial_ends_at?: string | null
          updated_at?: string
        }
        Update: {
          created_at?: string
          deleted_at?: string | null
          id?: string
          name?: string
          plan?: string
          settings?: Json
          slug?: string
          subscription_until?: string | null
          trial_ends_at?: string | null
          updated_at?: string
        }
        Relationships: []
      }
      diagnostics: {
        Row: {
          attachments: Json
          center_id: string
          conclusion: string | null
          created_at: string
          created_by: string | null
          custom_fields: Json
          date: string
          deleted_at: string | null
          id: string
          sounds: Json
          speech_areas: Json
          student_id: string
          teacher_id: string | null
          updated_at: string
        }
        Insert: {
          attachments?: Json
          center_id?: string
          conclusion?: string | null
          created_at?: string
          created_by?: string | null
          custom_fields?: Json
          date?: string
          deleted_at?: string | null
          id?: string
          sounds?: Json
          speech_areas?: Json
          student_id: string
          teacher_id?: string | null
          updated_at?: string
        }
        Update: {
          attachments?: Json
          center_id?: string
          conclusion?: string | null
          created_at?: string
          created_by?: string | null
          custom_fields?: Json
          date?: string
          deleted_at?: string | null
          id?: string
          sounds?: Json
          speech_areas?: Json
          student_id?: string
          teacher_id?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "diagnostics_center_id_fkey"
            columns: ["center_id"]
            isOneToOne: false
            referencedRelation: "centers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "diagnostics_student_fk"
            columns: ["student_id", "center_id"]
            isOneToOne: false
            referencedRelation: "students"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "diagnostics_student_fk"
            columns: ["student_id", "center_id"]
            isOneToOne: false
            referencedRelation: "students_teacher_view"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "diagnostics_teacher_fk"
            columns: ["teacher_id", "center_id"]
            isOneToOne: false
            referencedRelation: "teachers"
            referencedColumns: ["id", "center_id"]
          },
        ]
      }
      events: {
        Row: {
          attempts: number
          center_id: string
          claimed_at: string | null
          created_at: string
          id: number
          last_error: string | null
          payload: Json
          processed_at: string | null
          type: string
        }
        Insert: {
          attempts?: number
          center_id: string
          claimed_at?: string | null
          created_at?: string
          id?: number
          last_error?: string | null
          payload?: Json
          processed_at?: string | null
          type: string
        }
        Update: {
          attempts?: number
          center_id?: string
          claimed_at?: string | null
          created_at?: string
          id?: number
          last_error?: string | null
          payload?: Json
          processed_at?: string | null
          type?: string
        }
        Relationships: []
      }
      exercise_library: {
        Row: {
          age_from: number | null
          age_to: number | null
          area: string | null
          center_id: string | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          instructions: string | null
          is_active: boolean
          media_url: string | null
          sound: string | null
          stage_code: string | null
          tags: string[]
          title: string
          updated_at: string
        }
        Insert: {
          age_from?: number | null
          age_to?: number | null
          area?: string | null
          center_id?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          instructions?: string | null
          is_active?: boolean
          media_url?: string | null
          sound?: string | null
          stage_code?: string | null
          tags?: string[]
          title: string
          updated_at?: string
        }
        Update: {
          age_from?: number | null
          age_to?: number | null
          area?: string | null
          center_id?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          instructions?: string | null
          is_active?: boolean
          media_url?: string | null
          sound?: string | null
          stage_code?: string | null
          tags?: string[]
          title?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "exercise_library_center_id_fkey"
            columns: ["center_id"]
            isOneToOne: false
            referencedRelation: "centers"
            referencedColumns: ["id"]
          },
        ]
      }
      expense_categories: {
        Row: {
          center_id: string
          code: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          is_active: boolean
          name: string
          sort: number
          updated_at: string
        }
        Insert: {
          center_id?: string
          code: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          is_active?: boolean
          name: string
          sort?: number
          updated_at?: string
        }
        Update: {
          center_id?: string
          code?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          is_active?: boolean
          name?: string
          sort?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "expense_categories_center_id_fkey"
            columns: ["center_id"]
            isOneToOne: false
            referencedRelation: "centers"
            referencedColumns: ["id"]
          },
        ]
      }
      expenses: {
        Row: {
          amount_tiyin: number
          category_id: string
          center_id: string
          comment: string | null
          created_at: string
          created_by: string | null
          id: string
          kind: string
          paid_at: string
          source_id: string | null
          updated_at: string
        }
        Insert: {
          amount_tiyin: number
          category_id: string
          center_id?: string
          comment?: string | null
          created_at?: string
          created_by?: string | null
          id?: string
          kind?: string
          paid_at?: string
          source_id?: string | null
          updated_at?: string
        }
        Update: {
          amount_tiyin?: number
          category_id?: string
          center_id?: string
          comment?: string | null
          created_at?: string
          created_by?: string | null
          id?: string
          kind?: string
          paid_at?: string
          source_id?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "expenses_category_fk"
            columns: ["category_id", "center_id"]
            isOneToOne: false
            referencedRelation: "expense_categories"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "expenses_center_id_fkey"
            columns: ["center_id"]
            isOneToOne: false
            referencedRelation: "centers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expenses_source_fk"
            columns: ["source_id", "center_id"]
            isOneToOne: false
            referencedRelation: "payment_sources"
            referencedColumns: ["id", "center_id"]
          },
        ]
      }
      financial_periods: {
        Row: {
          center_id: string
          closed_at: string | null
          closed_by: string | null
          created_at: string
          id: string
          month: string
          updated_at: string
        }
        Insert: {
          center_id?: string
          closed_at?: string | null
          closed_by?: string | null
          created_at?: string
          id?: string
          month: string
          updated_at?: string
        }
        Update: {
          center_id?: string
          closed_at?: string | null
          closed_by?: string | null
          created_at?: string
          id?: string
          month?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "financial_periods_center_id_fkey"
            columns: ["center_id"]
            isOneToOne: false
            referencedRelation: "centers"
            referencedColumns: ["id"]
          },
        ]
      }
      goal_progress: {
        Row: {
          center_id: string
          conduct_key: string | null
          created_at: string
          created_by: string | null
          date: string
          deleted_at: string | null
          goal_id: string
          id: string
          lesson_id: string | null
          note: string | null
          score: number
          updated_at: string
        }
        Insert: {
          center_id?: string
          conduct_key?: string | null
          created_at?: string
          created_by?: string | null
          date?: string
          deleted_at?: string | null
          goal_id: string
          id?: string
          lesson_id?: string | null
          note?: string | null
          score: number
          updated_at?: string
        }
        Update: {
          center_id?: string
          conduct_key?: string | null
          created_at?: string
          created_by?: string | null
          date?: string
          deleted_at?: string | null
          goal_id?: string
          id?: string
          lesson_id?: string | null
          note?: string | null
          score?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "goal_progress_center_id_fkey"
            columns: ["center_id"]
            isOneToOne: false
            referencedRelation: "centers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "goal_progress_goal_fk"
            columns: ["goal_id", "center_id"]
            isOneToOne: false
            referencedRelation: "goals"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "goal_progress_lesson_fk"
            columns: ["lesson_id", "center_id"]
            isOneToOne: false
            referencedRelation: "lessons"
            referencedColumns: ["id", "center_id"]
          },
        ]
      }
      goal_stages: {
        Row: {
          center_id: string
          code: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          is_active: boolean
          sort: number
          title: string
          updated_at: string
        }
        Insert: {
          center_id?: string
          code: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          is_active?: boolean
          sort?: number
          title: string
          updated_at?: string
        }
        Update: {
          center_id?: string
          code?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          is_active?: boolean
          sort?: number
          title?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "goal_stages_center_id_fkey"
            columns: ["center_id"]
            isOneToOne: false
            referencedRelation: "centers"
            referencedColumns: ["id"]
          },
        ]
      }
      goals: {
        Row: {
          achieved_at: string | null
          area: string | null
          center_id: string
          created_at: string
          created_by: string | null
          custom_fields: Json
          deleted_at: string | null
          id: string
          sound: string | null
          stage_id: string
          status: string
          student_id: string
          target_date: string | null
          title: string
          updated_at: string
        }
        Insert: {
          achieved_at?: string | null
          area?: string | null
          center_id?: string
          created_at?: string
          created_by?: string | null
          custom_fields?: Json
          deleted_at?: string | null
          id?: string
          sound?: string | null
          stage_id: string
          status?: string
          student_id: string
          target_date?: string | null
          title: string
          updated_at?: string
        }
        Update: {
          achieved_at?: string | null
          area?: string | null
          center_id?: string
          created_at?: string
          created_by?: string | null
          custom_fields?: Json
          deleted_at?: string | null
          id?: string
          sound?: string | null
          stage_id?: string
          status?: string
          student_id?: string
          target_date?: string | null
          title?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "goals_center_id_fkey"
            columns: ["center_id"]
            isOneToOne: false
            referencedRelation: "centers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "goals_stage_fk"
            columns: ["stage_id", "center_id"]
            isOneToOne: false
            referencedRelation: "goal_stages"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "goals_student_fk"
            columns: ["student_id", "center_id"]
            isOneToOne: false
            referencedRelation: "students"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "goals_student_fk"
            columns: ["student_id", "center_id"]
            isOneToOne: false
            referencedRelation: "students_teacher_view"
            referencedColumns: ["id", "center_id"]
          },
        ]
      }
      group_students: {
        Row: {
          center_id: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          group_id: string
          id: string
          joined_at: string
          left_at: string | null
          student_id: string
          updated_at: string
        }
        Insert: {
          center_id?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          group_id: string
          id?: string
          joined_at?: string
          left_at?: string | null
          student_id: string
          updated_at?: string
        }
        Update: {
          center_id?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          group_id?: string
          id?: string
          joined_at?: string
          left_at?: string | null
          student_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "group_students_center_id_fkey"
            columns: ["center_id"]
            isOneToOne: false
            referencedRelation: "centers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "group_students_group_fk"
            columns: ["group_id", "center_id"]
            isOneToOne: false
            referencedRelation: "groups"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "group_students_student_fk"
            columns: ["student_id", "center_id"]
            isOneToOne: false
            referencedRelation: "students"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "group_students_student_fk"
            columns: ["student_id", "center_id"]
            isOneToOne: false
            referencedRelation: "students_teacher_view"
            referencedColumns: ["id", "center_id"]
          },
        ]
      }
      groups: {
        Row: {
          center_id: string
          created_at: string
          created_by: string | null
          custom_fields: Json
          deleted_at: string | null
          id: string
          is_active: boolean
          max_students: number | null
          name: string
          room_id: string | null
          service_id: string | null
          teacher_id: string | null
          updated_at: string
        }
        Insert: {
          center_id?: string
          created_at?: string
          created_by?: string | null
          custom_fields?: Json
          deleted_at?: string | null
          id?: string
          is_active?: boolean
          max_students?: number | null
          name: string
          room_id?: string | null
          service_id?: string | null
          teacher_id?: string | null
          updated_at?: string
        }
        Update: {
          center_id?: string
          created_at?: string
          created_by?: string | null
          custom_fields?: Json
          deleted_at?: string | null
          id?: string
          is_active?: boolean
          max_students?: number | null
          name?: string
          room_id?: string | null
          service_id?: string | null
          teacher_id?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "groups_center_id_fkey"
            columns: ["center_id"]
            isOneToOne: false
            referencedRelation: "centers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "groups_room_fk"
            columns: ["room_id", "center_id"]
            isOneToOne: false
            referencedRelation: "rooms"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "groups_service_fk"
            columns: ["service_id", "center_id"]
            isOneToOne: false
            referencedRelation: "services"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "groups_teacher_fk"
            columns: ["teacher_id", "center_id"]
            isOneToOne: false
            referencedRelation: "teachers"
            referencedColumns: ["id", "center_id"]
          },
        ]
      }
      homework: {
        Row: {
          assigned_at: string
          center_id: string
          conduct_key: string | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          due_on: string | null
          free_text: string | null
          id: string
          lesson_id: string | null
          parent_note: string | null
          status: string
          student_id: string
          teacher_feedback: string | null
          updated_at: string
        }
        Insert: {
          assigned_at?: string
          center_id?: string
          conduct_key?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          due_on?: string | null
          free_text?: string | null
          id?: string
          lesson_id?: string | null
          parent_note?: string | null
          status?: string
          student_id: string
          teacher_feedback?: string | null
          updated_at?: string
        }
        Update: {
          assigned_at?: string
          center_id?: string
          conduct_key?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          due_on?: string | null
          free_text?: string | null
          id?: string
          lesson_id?: string | null
          parent_note?: string | null
          status?: string
          student_id?: string
          teacher_feedback?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "homework_center_id_fkey"
            columns: ["center_id"]
            isOneToOne: false
            referencedRelation: "centers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "homework_lesson_fk"
            columns: ["lesson_id", "center_id"]
            isOneToOne: false
            referencedRelation: "lessons"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "homework_student_fk"
            columns: ["student_id", "center_id"]
            isOneToOne: false
            referencedRelation: "students"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "homework_student_fk"
            columns: ["student_id", "center_id"]
            isOneToOne: false
            referencedRelation: "students_teacher_view"
            referencedColumns: ["id", "center_id"]
          },
        ]
      }
      homework_exercises: {
        Row: {
          center_id: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          exercise_id: string
          homework_id: string
          id: string
          sort: number
          updated_at: string
        }
        Insert: {
          center_id?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          exercise_id: string
          homework_id: string
          id?: string
          sort?: number
          updated_at?: string
        }
        Update: {
          center_id?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          exercise_id?: string
          homework_id?: string
          id?: string
          sort?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "homework_exercises_exercise_id_fkey"
            columns: ["exercise_id"]
            isOneToOne: false
            referencedRelation: "exercise_library"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "homework_exercises_homework_fk"
            columns: ["homework_id", "center_id"]
            isOneToOne: false
            referencedRelation: "homework"
            referencedColumns: ["id", "center_id"]
          },
        ]
      }
      installment_plans: {
        Row: {
          base_paid_tiyin: number
          cancelled_at: string | null
          center_id: string
          created_at: string
          created_by: string | null
          id: string
          payer_id: string
          student_id: string
          subscription_id: string
          updated_at: string
        }
        Insert: {
          base_paid_tiyin: number
          cancelled_at?: string | null
          center_id?: string
          created_at?: string
          created_by?: string | null
          id?: string
          payer_id: string
          student_id: string
          subscription_id: string
          updated_at?: string
        }
        Update: {
          base_paid_tiyin?: number
          cancelled_at?: string | null
          center_id?: string
          created_at?: string
          created_by?: string | null
          id?: string
          payer_id?: string
          student_id?: string
          subscription_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "installment_plans_center_id_fkey"
            columns: ["center_id"]
            isOneToOne: false
            referencedRelation: "centers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "installment_plans_student_payer_fk"
            columns: ["student_id", "payer_id", "center_id"]
            isOneToOne: false
            referencedRelation: "student_payers"
            referencedColumns: ["student_id", "payer_id", "center_id"]
          },
          {
            foreignKeyName: "installment_plans_subscription_fk"
            columns: ["subscription_id", "student_id", "center_id"]
            isOneToOne: false
            referencedRelation: "subscriptions"
            referencedColumns: ["id", "student_id", "center_id"]
          },
        ]
      }
      installments: {
        Row: {
          amount_tiyin: number
          center_id: string
          created_at: string
          created_by: string | null
          due_date: string
          due_notified_at: string | null
          id: string
          overdue_notified_at: string | null
          payer_id: string
          plan_id: string
          seq: number
          student_id: string
          subscription_id: string
          updated_at: string
        }
        Insert: {
          amount_tiyin: number
          center_id?: string
          created_at?: string
          created_by?: string | null
          due_date: string
          due_notified_at?: string | null
          id?: string
          overdue_notified_at?: string | null
          payer_id: string
          plan_id: string
          seq: number
          student_id: string
          subscription_id: string
          updated_at?: string
        }
        Update: {
          amount_tiyin?: number
          center_id?: string
          created_at?: string
          created_by?: string | null
          due_date?: string
          due_notified_at?: string | null
          id?: string
          overdue_notified_at?: string | null
          payer_id?: string
          plan_id?: string
          seq?: number
          student_id?: string
          subscription_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "installments_center_id_fkey"
            columns: ["center_id"]
            isOneToOne: false
            referencedRelation: "centers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "installments_plan_fk"
            columns: [
              "plan_id",
              "subscription_id",
              "student_id",
              "payer_id",
              "center_id",
            ]
            isOneToOne: false
            referencedRelation: "installment_plans"
            referencedColumns: [
              "id",
              "subscription_id",
              "student_id",
              "payer_id",
              "center_id",
            ]
          },
          {
            foreignKeyName: "installments_student_payer_fk"
            columns: ["student_id", "payer_id", "center_id"]
            isOneToOne: false
            referencedRelation: "student_payers"
            referencedColumns: ["student_id", "payer_id", "center_id"]
          },
          {
            foreignKeyName: "installments_subscription_fk"
            columns: ["subscription_id", "student_id", "center_id"]
            isOneToOne: false
            referencedRelation: "subscriptions"
            referencedColumns: ["id", "student_id", "center_id"]
          },
        ]
      }
      invitations: {
        Row: {
          accepted_at: string | null
          accepted_by: string | null
          center_id: string
          created_at: string
          created_by: string | null
          email: string | null
          expires_at: string
          id: string
          payer_id: string | null
          phone: string | null
          role: string
          teacher_id: string | null
          token: string
        }
        Insert: {
          accepted_at?: string | null
          accepted_by?: string | null
          center_id?: string
          created_at?: string
          created_by?: string | null
          email?: string | null
          expires_at?: string
          id?: string
          payer_id?: string | null
          phone?: string | null
          role: string
          teacher_id?: string | null
          token?: string
        }
        Update: {
          accepted_at?: string | null
          accepted_by?: string | null
          center_id?: string
          created_at?: string
          created_by?: string | null
          email?: string | null
          expires_at?: string
          id?: string
          payer_id?: string | null
          phone?: string | null
          role?: string
          teacher_id?: string | null
          token?: string
        }
        Relationships: [
          {
            foreignKeyName: "invitations_center_id_fkey"
            columns: ["center_id"]
            isOneToOne: false
            referencedRelation: "centers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invitations_payer_fk"
            columns: ["payer_id", "center_id"]
            isOneToOne: false
            referencedRelation: "payers"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "invitations_payer_fk"
            columns: ["payer_id", "center_id"]
            isOneToOne: false
            referencedRelation: "payers_with_stats"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "invitations_teacher_fk"
            columns: ["teacher_id", "center_id"]
            isOneToOne: false
            referencedRelation: "teachers"
            referencedColumns: ["id", "center_id"]
          },
        ]
      }
      lesson_confirmations: {
        Row: {
          center_id: string
          confirmed_at: string
          confirmed_by: string | null
          id: string
          lesson_id: string
          source: string
          student_id: string
        }
        Insert: {
          center_id: string
          confirmed_at?: string
          confirmed_by?: string | null
          id?: string
          lesson_id: string
          source?: string
          student_id: string
        }
        Update: {
          center_id?: string
          confirmed_at?: string
          confirmed_by?: string | null
          id?: string
          lesson_id?: string
          source?: string
          student_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "lesson_confirmations_center_id_fkey"
            columns: ["center_id"]
            isOneToOne: false
            referencedRelation: "centers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "lesson_confirmations_lesson_fk"
            columns: ["lesson_id", "center_id"]
            isOneToOne: false
            referencedRelation: "lessons"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "lesson_confirmations_student_fk"
            columns: ["student_id", "center_id"]
            isOneToOne: false
            referencedRelation: "students"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "lesson_confirmations_student_fk"
            columns: ["student_id", "center_id"]
            isOneToOne: false
            referencedRelation: "students_teacher_view"
            referencedColumns: ["id", "center_id"]
          },
        ]
      }
      lesson_notes: {
        Row: {
          approved_at: string | null
          approved_by: string | null
          center_id: string
          conduct_key: string | null
          cost_tiyin: number | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          lesson_id: string
          model: string | null
          parent_summary: string | null
          raw_transcript: string | null
          soap: Json
          source: string
          status: string
          student_id: string
          teacher_id: string | null
          tokens_in: number | null
          tokens_out: number | null
          updated_at: string
        }
        Insert: {
          approved_at?: string | null
          approved_by?: string | null
          center_id?: string
          conduct_key?: string | null
          cost_tiyin?: number | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          lesson_id: string
          model?: string | null
          parent_summary?: string | null
          raw_transcript?: string | null
          soap?: Json
          source?: string
          status?: string
          student_id: string
          teacher_id?: string | null
          tokens_in?: number | null
          tokens_out?: number | null
          updated_at?: string
        }
        Update: {
          approved_at?: string | null
          approved_by?: string | null
          center_id?: string
          conduct_key?: string | null
          cost_tiyin?: number | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          lesson_id?: string
          model?: string | null
          parent_summary?: string | null
          raw_transcript?: string | null
          soap?: Json
          source?: string
          status?: string
          student_id?: string
          teacher_id?: string | null
          tokens_in?: number | null
          tokens_out?: number | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "lesson_notes_center_id_fkey"
            columns: ["center_id"]
            isOneToOne: false
            referencedRelation: "centers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "lesson_notes_lesson_fk"
            columns: ["lesson_id", "center_id"]
            isOneToOne: false
            referencedRelation: "lessons"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "lesson_notes_student_fk"
            columns: ["student_id", "center_id"]
            isOneToOne: false
            referencedRelation: "students"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "lesson_notes_student_fk"
            columns: ["student_id", "center_id"]
            isOneToOne: false
            referencedRelation: "students_teacher_view"
            referencedColumns: ["id", "center_id"]
          },
        ]
      }
      lesson_participants: {
        Row: {
          center_id: string
          deleted_at: string | null
          ends_at: string
          lesson_id: string
          starts_at: string
          status: string
          student_id: string
        }
        Insert: {
          center_id: string
          deleted_at?: string | null
          ends_at: string
          lesson_id: string
          starts_at: string
          status?: string
          student_id: string
        }
        Update: {
          center_id?: string
          deleted_at?: string | null
          ends_at?: string
          lesson_id?: string
          starts_at?: string
          status?: string
          student_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "lesson_participants_lesson_fk"
            columns: ["lesson_id", "center_id"]
            isOneToOne: false
            referencedRelation: "lessons"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "lesson_participants_student_fk"
            columns: ["student_id", "center_id"]
            isOneToOne: false
            referencedRelation: "students"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "lesson_participants_student_fk"
            columns: ["student_id", "center_id"]
            isOneToOne: false
            referencedRelation: "students_teacher_view"
            referencedColumns: ["id", "center_id"]
          },
        ]
      }
      lesson_reminders_sent: {
        Row: {
          center_id: string
          lesson_id: string
          sent_at: string
        }
        Insert: {
          center_id: string
          lesson_id: string
          sent_at?: string
        }
        Update: {
          center_id?: string
          lesson_id?: string
          sent_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "lesson_reminders_sent_center_id_fkey"
            columns: ["center_id"]
            isOneToOne: false
            referencedRelation: "centers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "lesson_reminders_sent_lesson_fk"
            columns: ["lesson_id", "center_id"]
            isOneToOne: false
            referencedRelation: "lessons"
            referencedColumns: ["id", "center_id"]
          },
        ]
      }
      lessons: {
        Row: {
          cancel_reason: string | null
          center_id: string
          created_at: string
          created_by: string | null
          custom_fields: Json
          deleted_at: string | null
          effective_teacher_id: string | null
          ends_at: string
          group_id: string | null
          id: string
          notes: string | null
          room_id: string | null
          series_id: string | null
          service_id: string | null
          starts_at: string
          status: string
          student_id: string | null
          substitute_teacher_id: string | null
          teacher_id: string
          updated_at: string
        }
        Insert: {
          cancel_reason?: string | null
          center_id?: string
          created_at?: string
          created_by?: string | null
          custom_fields?: Json
          deleted_at?: string | null
          effective_teacher_id?: string | null
          ends_at: string
          group_id?: string | null
          id?: string
          notes?: string | null
          room_id?: string | null
          series_id?: string | null
          service_id?: string | null
          starts_at: string
          status?: string
          student_id?: string | null
          substitute_teacher_id?: string | null
          teacher_id: string
          updated_at?: string
        }
        Update: {
          cancel_reason?: string | null
          center_id?: string
          created_at?: string
          created_by?: string | null
          custom_fields?: Json
          deleted_at?: string | null
          effective_teacher_id?: string | null
          ends_at?: string
          group_id?: string | null
          id?: string
          notes?: string | null
          room_id?: string | null
          series_id?: string | null
          service_id?: string | null
          starts_at?: string
          status?: string
          student_id?: string | null
          substitute_teacher_id?: string | null
          teacher_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "lessons_center_id_fkey"
            columns: ["center_id"]
            isOneToOne: false
            referencedRelation: "centers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "lessons_group_fk"
            columns: ["group_id", "center_id"]
            isOneToOne: false
            referencedRelation: "groups"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "lessons_room_fk"
            columns: ["room_id", "center_id"]
            isOneToOne: false
            referencedRelation: "rooms"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "lessons_service_fk"
            columns: ["service_id", "center_id"]
            isOneToOne: false
            referencedRelation: "services"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "lessons_student_fk"
            columns: ["student_id", "center_id"]
            isOneToOne: false
            referencedRelation: "students"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "lessons_student_fk"
            columns: ["student_id", "center_id"]
            isOneToOne: false
            referencedRelation: "students_teacher_view"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "lessons_substitute_teacher_fk"
            columns: ["substitute_teacher_id", "center_id"]
            isOneToOne: false
            referencedRelation: "teachers"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "lessons_teacher_fk"
            columns: ["teacher_id", "center_id"]
            isOneToOne: false
            referencedRelation: "teachers"
            referencedColumns: ["id", "center_id"]
          },
        ]
      }
      memberships: {
        Row: {
          center_id: string
          created_at: string
          payer_id: string | null
          role: string
          teacher_id: string | null
          user_id: string
        }
        Insert: {
          center_id: string
          created_at?: string
          payer_id?: string | null
          role: string
          teacher_id?: string | null
          user_id: string
        }
        Update: {
          center_id?: string
          created_at?: string
          payer_id?: string | null
          role?: string
          teacher_id?: string | null
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "memberships_center_id_fkey"
            columns: ["center_id"]
            isOneToOne: false
            referencedRelation: "centers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "memberships_payer_fk"
            columns: ["payer_id", "center_id"]
            isOneToOne: false
            referencedRelation: "payers"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "memberships_payer_fk"
            columns: ["payer_id", "center_id"]
            isOneToOne: false
            referencedRelation: "payers_with_stats"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "memberships_teacher_fk"
            columns: ["teacher_id", "center_id"]
            isOneToOne: false
            referencedRelation: "teachers"
            referencedColumns: ["id", "center_id"]
          },
        ]
      }
      message_templates: {
        Row: {
          center_id: string | null
          channel: string
          created_at: string
          created_by: string | null
          custom_fields: Json
          deleted_at: string | null
          event_type: string
          id: string
          is_active: boolean
          text: string
          updated_at: string
        }
        Insert: {
          center_id?: string | null
          channel: string
          created_at?: string
          created_by?: string | null
          custom_fields?: Json
          deleted_at?: string | null
          event_type: string
          id?: string
          is_active?: boolean
          text: string
          updated_at?: string
        }
        Update: {
          center_id?: string | null
          channel?: string
          created_at?: string
          created_by?: string | null
          custom_fields?: Json
          deleted_at?: string | null
          event_type?: string
          id?: string
          is_active?: boolean
          text?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "message_templates_center_id_fkey"
            columns: ["center_id"]
            isOneToOne: false
            referencedRelation: "centers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "message_templates_event_type_fk"
            columns: ["event_type"]
            isOneToOne: false
            referencedRelation: "notification_event_types"
            referencedColumns: ["event_type"]
          },
        ]
      }
      notification_event_types: {
        Row: {
          description: string
          event_type: string
        }
        Insert: {
          description: string
          event_type: string
        }
        Update: {
          description?: string
          event_type?: string
        }
        Relationships: []
      }
      notification_log: {
        Row: {
          attempts: number
          center_id: string
          channel: string
          created_at: string
          error: string | null
          event_id: number
          id: string
          recipient_user_id: string | null
          sent_at: string | null
          status: string
          subject_id: string | null
          text: string | null
          updated_at: string
        }
        Insert: {
          attempts?: number
          center_id: string
          channel: string
          created_at?: string
          error?: string | null
          event_id: number
          id?: string
          recipient_user_id?: string | null
          sent_at?: string | null
          status?: string
          subject_id?: string | null
          text?: string | null
          updated_at?: string
        }
        Update: {
          attempts?: number
          center_id?: string
          channel?: string
          created_at?: string
          error?: string | null
          event_id?: number
          id?: string
          recipient_user_id?: string | null
          sent_at?: string | null
          status?: string
          subject_id?: string | null
          text?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "notification_log_center_id_fkey"
            columns: ["center_id"]
            isOneToOne: false
            referencedRelation: "centers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "notification_log_event_id_fkey"
            columns: ["event_id"]
            isOneToOne: false
            referencedRelation: "events"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "notification_log_subject_fk"
            columns: ["subject_id", "center_id"]
            isOneToOne: false
            referencedRelation: "students"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "notification_log_subject_fk"
            columns: ["subject_id", "center_id"]
            isOneToOne: false
            referencedRelation: "students_teacher_view"
            referencedColumns: ["id", "center_id"]
          },
        ]
      }
      payers: {
        Row: {
          center_id: string
          created_at: string
          created_by: string | null
          custom_fields: Json
          deleted_at: string | null
          email: string | null
          full_name: string
          id: string
          notes: string | null
          phone: string
          phone_alt: string | null
          relation: string | null
          updated_at: string
        }
        Insert: {
          center_id?: string
          created_at?: string
          created_by?: string | null
          custom_fields?: Json
          deleted_at?: string | null
          email?: string | null
          full_name: string
          id?: string
          notes?: string | null
          phone: string
          phone_alt?: string | null
          relation?: string | null
          updated_at?: string
        }
        Update: {
          center_id?: string
          created_at?: string
          created_by?: string | null
          custom_fields?: Json
          deleted_at?: string | null
          email?: string | null
          full_name?: string
          id?: string
          notes?: string | null
          phone?: string
          phone_alt?: string | null
          relation?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "payers_center_id_fkey"
            columns: ["center_id"]
            isOneToOne: false
            referencedRelation: "centers"
            referencedColumns: ["id"]
          },
        ]
      }
      payment_sources: {
        Row: {
          center_id: string
          code: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          is_active: boolean
          name: string
          sort: number
          updated_at: string
        }
        Insert: {
          center_id?: string
          code: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          is_active?: boolean
          name: string
          sort?: number
          updated_at?: string
        }
        Update: {
          center_id?: string
          code?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          is_active?: boolean
          name?: string
          sort?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "payment_sources_center_id_fkey"
            columns: ["center_id"]
            isOneToOne: false
            referencedRelation: "centers"
            referencedColumns: ["id"]
          },
        ]
      }
      payments: {
        Row: {
          amount_tiyin: number
          center_id: string
          comment: string | null
          created_at: string
          created_by: string | null
          id: string
          kind: string
          paid_at: string
          payer_id: string
          source_id: string | null
          student_id: string | null
          subscription_id: string | null
          updated_at: string
        }
        Insert: {
          amount_tiyin: number
          center_id?: string
          comment?: string | null
          created_at?: string
          created_by?: string | null
          id?: string
          kind?: string
          paid_at?: string
          payer_id: string
          source_id?: string | null
          student_id?: string | null
          subscription_id?: string | null
          updated_at?: string
        }
        Update: {
          amount_tiyin?: number
          center_id?: string
          comment?: string | null
          created_at?: string
          created_by?: string | null
          id?: string
          kind?: string
          paid_at?: string
          payer_id?: string
          source_id?: string | null
          student_id?: string | null
          subscription_id?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "payments_center_id_fkey"
            columns: ["center_id"]
            isOneToOne: false
            referencedRelation: "centers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payments_payer_fk"
            columns: ["payer_id", "center_id"]
            isOneToOne: false
            referencedRelation: "payers"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "payments_payer_fk"
            columns: ["payer_id", "center_id"]
            isOneToOne: false
            referencedRelation: "payers_with_stats"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "payments_source_fk"
            columns: ["source_id", "center_id"]
            isOneToOne: false
            referencedRelation: "payment_sources"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "payments_student_payer_fk"
            columns: ["student_id", "payer_id", "center_id"]
            isOneToOne: false
            referencedRelation: "student_payers"
            referencedColumns: ["student_id", "payer_id", "center_id"]
          },
          {
            foreignKeyName: "payments_subscription_fk"
            columns: ["subscription_id", "student_id", "center_id"]
            isOneToOne: false
            referencedRelation: "subscriptions"
            referencedColumns: ["id", "student_id", "center_id"]
          },
        ]
      }
      rooms: {
        Row: {
          capacity: number
          center_id: string
          created_at: string
          created_by: string | null
          custom_fields: Json
          deleted_at: string | null
          id: string
          is_active: boolean
          name: string
          updated_at: string
        }
        Insert: {
          capacity?: number
          center_id?: string
          created_at?: string
          created_by?: string | null
          custom_fields?: Json
          deleted_at?: string | null
          id?: string
          is_active?: boolean
          name: string
          updated_at?: string
        }
        Update: {
          capacity?: number
          center_id?: string
          created_at?: string
          created_by?: string | null
          custom_fields?: Json
          deleted_at?: string | null
          id?: string
          is_active?: boolean
          name?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "rooms_center_id_fkey"
            columns: ["center_id"]
            isOneToOne: false
            referencedRelation: "centers"
            referencedColumns: ["id"]
          },
        ]
      }
      salary_adjustments: {
        Row: {
          amount_tiyin: number
          center_id: string
          created_at: string
          created_by: string | null
          id: string
          month: string
          reason: string
          teacher_id: string
        }
        Insert: {
          amount_tiyin: number
          center_id?: string
          created_at?: string
          created_by?: string | null
          id?: string
          month: string
          reason: string
          teacher_id: string
        }
        Update: {
          amount_tiyin?: number
          center_id?: string
          created_at?: string
          created_by?: string | null
          id?: string
          month?: string
          reason?: string
          teacher_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "salary_adjustments_center_id_fkey"
            columns: ["center_id"]
            isOneToOne: false
            referencedRelation: "centers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "salary_adjustments_teacher_fk"
            columns: ["teacher_id", "center_id"]
            isOneToOne: false
            referencedRelation: "teachers"
            referencedColumns: ["id", "center_id"]
          },
        ]
      }
      salary_runs: {
        Row: {
          approved_at: string
          approved_by: string | null
          cancelled_at: string | null
          cancelled_by: string | null
          center_id: string
          id: string
          lines: Json
          month: string
          teacher_id: string
          total_tiyin: number
        }
        Insert: {
          approved_at?: string
          approved_by?: string | null
          cancelled_at?: string | null
          cancelled_by?: string | null
          center_id?: string
          id?: string
          lines: Json
          month: string
          teacher_id: string
          total_tiyin: number
        }
        Update: {
          approved_at?: string
          approved_by?: string | null
          cancelled_at?: string | null
          cancelled_by?: string | null
          center_id?: string
          id?: string
          lines?: Json
          month?: string
          teacher_id?: string
          total_tiyin?: number
        }
        Relationships: [
          {
            foreignKeyName: "salary_runs_center_id_fkey"
            columns: ["center_id"]
            isOneToOne: false
            referencedRelation: "centers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "salary_runs_teacher_fk"
            columns: ["teacher_id", "center_id"]
            isOneToOne: false
            referencedRelation: "teachers"
            referencedColumns: ["id", "center_id"]
          },
        ]
      }
      services: {
        Row: {
          center_id: string
          created_at: string
          created_by: string | null
          custom_fields: Json
          default_price_tiyin: number | null
          deleted_at: string | null
          duration_min: number
          id: string
          is_active: boolean
          kind: string
          name: string
          updated_at: string
        }
        Insert: {
          center_id?: string
          created_at?: string
          created_by?: string | null
          custom_fields?: Json
          default_price_tiyin?: number | null
          deleted_at?: string | null
          duration_min?: number
          id?: string
          is_active?: boolean
          kind?: string
          name: string
          updated_at?: string
        }
        Update: {
          center_id?: string
          created_at?: string
          created_by?: string | null
          custom_fields?: Json
          default_price_tiyin?: number | null
          deleted_at?: string | null
          duration_min?: number
          id?: string
          is_active?: boolean
          kind?: string
          name?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "services_center_id_fkey"
            columns: ["center_id"]
            isOneToOne: false
            referencedRelation: "centers"
            referencedColumns: ["id"]
          },
        ]
      }
      student_payers: {
        Row: {
          center_id: string
          created_at: string
          created_by: string | null
          id: string
          payer_id: string
          student_id: string
        }
        Insert: {
          center_id?: string
          created_at?: string
          created_by?: string | null
          id?: string
          payer_id: string
          student_id: string
        }
        Update: {
          center_id?: string
          created_at?: string
          created_by?: string | null
          id?: string
          payer_id?: string
          student_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "student_payers_center_id_fkey"
            columns: ["center_id"]
            isOneToOne: false
            referencedRelation: "centers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "student_payers_payer_fk"
            columns: ["payer_id", "center_id"]
            isOneToOne: false
            referencedRelation: "payers"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "student_payers_payer_fk"
            columns: ["payer_id", "center_id"]
            isOneToOne: false
            referencedRelation: "payers_with_stats"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "student_payers_student_fk"
            columns: ["student_id", "center_id"]
            isOneToOne: false
            referencedRelation: "students"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "student_payers_student_fk"
            columns: ["student_id", "center_id"]
            isOneToOne: false
            referencedRelation: "students_teacher_view"
            referencedColumns: ["id", "center_id"]
          },
        ]
      }
      students: {
        Row: {
          birth_date: string | null
          center_id: string
          created_at: string
          created_by: string | null
          custom_fields: Json
          deleted_at: string | null
          full_name: string
          gender: string | null
          id: string
          notes: string | null
          payer_id: string
          primary_teacher_id: string | null
          source: string | null
          started_at: string | null
          status: string
          updated_at: string
        }
        Insert: {
          birth_date?: string | null
          center_id?: string
          created_at?: string
          created_by?: string | null
          custom_fields?: Json
          deleted_at?: string | null
          full_name: string
          gender?: string | null
          id?: string
          notes?: string | null
          payer_id: string
          primary_teacher_id?: string | null
          source?: string | null
          started_at?: string | null
          status?: string
          updated_at?: string
        }
        Update: {
          birth_date?: string | null
          center_id?: string
          created_at?: string
          created_by?: string | null
          custom_fields?: Json
          deleted_at?: string | null
          full_name?: string
          gender?: string | null
          id?: string
          notes?: string | null
          payer_id?: string
          primary_teacher_id?: string | null
          source?: string | null
          started_at?: string | null
          status?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "students_center_id_fkey"
            columns: ["center_id"]
            isOneToOne: false
            referencedRelation: "centers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "students_payer_fk"
            columns: ["payer_id", "center_id"]
            isOneToOne: false
            referencedRelation: "payers"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "students_payer_fk"
            columns: ["payer_id", "center_id"]
            isOneToOne: false
            referencedRelation: "payers_with_stats"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "students_primary_teacher_fk"
            columns: ["primary_teacher_id", "center_id"]
            isOneToOne: false
            referencedRelation: "teachers"
            referencedColumns: ["id", "center_id"]
          },
        ]
      }
      subscription_freezes: {
        Row: {
          center_id: string
          created_at: string
          created_by: string | null
          id: string
          period: unknown
          reason: string | null
          subscription_id: string
        }
        Insert: {
          center_id?: string
          created_at?: string
          created_by?: string | null
          id?: string
          period: unknown
          reason?: string | null
          subscription_id: string
        }
        Update: {
          center_id?: string
          created_at?: string
          created_by?: string | null
          id?: string
          period?: unknown
          reason?: string | null
          subscription_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "subscription_freezes_center_id_fkey"
            columns: ["center_id"]
            isOneToOne: false
            referencedRelation: "centers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "subscription_freezes_sub_fk"
            columns: ["subscription_id", "center_id"]
            isOneToOne: false
            referencedRelation: "subscriptions"
            referencedColumns: ["id", "center_id"]
          },
        ]
      }
      subscription_types: {
        Row: {
          center_id: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          is_active: boolean
          kind: string
          lessons_count: number | null
          name: string
          period_days: number | null
          price_tiyin: number
          service_id: string | null
          updated_at: string
        }
        Insert: {
          center_id?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          is_active?: boolean
          kind?: string
          lessons_count?: number | null
          name: string
          period_days?: number | null
          price_tiyin: number
          service_id?: string | null
          updated_at?: string
        }
        Update: {
          center_id?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          is_active?: boolean
          kind?: string
          lessons_count?: number | null
          name?: string
          period_days?: number | null
          price_tiyin?: number
          service_id?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "subscription_types_center_id_fkey"
            columns: ["center_id"]
            isOneToOne: false
            referencedRelation: "centers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "subscription_types_service_fk"
            columns: ["service_id", "center_id"]
            isOneToOne: false
            referencedRelation: "services"
            referencedColumns: ["id", "center_id"]
          },
        ]
      }
      subscriptions: {
        Row: {
          allow_negative: boolean
          center_id: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          ends_at: string | null
          id: string
          lesson_price_tiyin: number | null
          lessons_total: number | null
          lessons_used: number
          lessons_written_off: number
          notes: string | null
          paid_tiyin: number
          payer_id: string
          price_tiyin: number
          sale_key: string | null
          starts_at: string
          status: string
          student_id: string
          type_id: string | null
          updated_at: string
        }
        Insert: {
          allow_negative?: boolean
          center_id?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          ends_at?: string | null
          id?: string
          lesson_price_tiyin?: number | null
          lessons_total?: number | null
          lessons_used?: number
          lessons_written_off?: number
          notes?: string | null
          paid_tiyin?: number
          payer_id: string
          price_tiyin: number
          sale_key?: string | null
          starts_at: string
          status?: string
          student_id: string
          type_id?: string | null
          updated_at?: string
        }
        Update: {
          allow_negative?: boolean
          center_id?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          ends_at?: string | null
          id?: string
          lesson_price_tiyin?: number | null
          lessons_total?: number | null
          lessons_used?: number
          lessons_written_off?: number
          notes?: string | null
          paid_tiyin?: number
          payer_id?: string
          price_tiyin?: number
          sale_key?: string | null
          starts_at?: string
          status?: string
          student_id?: string
          type_id?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "subscriptions_center_id_fkey"
            columns: ["center_id"]
            isOneToOne: false
            referencedRelation: "centers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "subscriptions_payer_fk"
            columns: ["payer_id", "center_id"]
            isOneToOne: false
            referencedRelation: "payers"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "subscriptions_payer_fk"
            columns: ["payer_id", "center_id"]
            isOneToOne: false
            referencedRelation: "payers_with_stats"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "subscriptions_student_fk"
            columns: ["student_id", "center_id"]
            isOneToOne: false
            referencedRelation: "students"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "subscriptions_student_fk"
            columns: ["student_id", "center_id"]
            isOneToOne: false
            referencedRelation: "students_teacher_view"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "subscriptions_type_fk"
            columns: ["type_id", "center_id"]
            isOneToOne: false
            referencedRelation: "subscription_types"
            referencedColumns: ["id", "center_id"]
          },
        ]
      }
      teacher_rates: {
        Row: {
          center_id: string
          created_at: string
          created_by: string | null
          id: string
          model: string
          service_id: string | null
          teacher_id: string
          valid_from: string
          value: number
        }
        Insert: {
          center_id?: string
          created_at?: string
          created_by?: string | null
          id?: string
          model: string
          service_id?: string | null
          teacher_id: string
          valid_from?: string
          value: number
        }
        Update: {
          center_id?: string
          created_at?: string
          created_by?: string | null
          id?: string
          model?: string
          service_id?: string | null
          teacher_id?: string
          valid_from?: string
          value?: number
        }
        Relationships: [
          {
            foreignKeyName: "teacher_rates_center_id_fkey"
            columns: ["center_id"]
            isOneToOne: false
            referencedRelation: "centers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "teacher_rates_service_fk"
            columns: ["service_id", "center_id"]
            isOneToOne: false
            referencedRelation: "services"
            referencedColumns: ["id", "center_id"]
          },
          {
            foreignKeyName: "teacher_rates_teacher_fk"
            columns: ["teacher_id", "center_id"]
            isOneToOne: false
            referencedRelation: "teachers"
            referencedColumns: ["id", "center_id"]
          },
        ]
      }
      teachers: {
        Row: {
          center_id: string
          created_at: string
          created_by: string | null
          custom_fields: Json
          deleted_at: string | null
          full_name: string
          hourly_rate_tiyin: number | null
          id: string
          is_active: boolean
          phone: string | null
          profile_id: string | null
          specialization: string | null
          updated_at: string
        }
        Insert: {
          center_id?: string
          created_at?: string
          created_by?: string | null
          custom_fields?: Json
          deleted_at?: string | null
          full_name: string
          hourly_rate_tiyin?: number | null
          id?: string
          is_active?: boolean
          phone?: string | null
          profile_id?: string | null
          specialization?: string | null
          updated_at?: string
        }
        Update: {
          center_id?: string
          created_at?: string
          created_by?: string | null
          custom_fields?: Json
          deleted_at?: string | null
          full_name?: string
          hourly_rate_tiyin?: number | null
          id?: string
          is_active?: boolean
          phone?: string | null
          profile_id?: string | null
          specialization?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "teachers_center_id_fkey"
            columns: ["center_id"]
            isOneToOne: false
            referencedRelation: "centers"
            referencedColumns: ["id"]
          },
        ]
      }
      telegram_accounts: {
        Row: {
          chat_id: number
          id: string
          linked_at: string
          unlinked_at: string | null
          user_id: string
        }
        Insert: {
          chat_id: number
          id?: string
          linked_at?: string
          unlinked_at?: string | null
          user_id: string
        }
        Update: {
          chat_id?: number
          id?: string
          linked_at?: string
          unlinked_at?: string | null
          user_id?: string
        }
        Relationships: []
      }
      telegram_link_codes: {
        Row: {
          code: string
          created_at: string
          expires_at: string
          used_at: string | null
          user_id: string
        }
        Insert: {
          code: string
          created_at?: string
          expires_at: string
          used_at?: string | null
          user_id: string
        }
        Update: {
          code?: string
          created_at?: string
          expires_at?: string
          used_at?: string | null
          user_id?: string
        }
        Relationships: []
      }
    }
    Views: {
      cash_by_source: {
        Row: {
          center_id: string | null
          corrections_tiyin: number | null
          month: string | null
          other_tiyin: number | null
          received_tiyin: number | null
          refunded_tiyin: number | null
          source_id: string | null
          spent_tiyin: number | null
          total_tiyin: number | null
        }
        Relationships: []
      }
      installments_view: {
        Row: {
          amount_tiyin: number | null
          base_paid_tiyin: number | null
          cancelled_at: string | null
          center_id: string | null
          created_at: string | null
          cumulative_tiyin: number | null
          due_date: string | null
          due_notified_at: string | null
          id: string | null
          overdue_notified_at: string | null
          paid_tiyin: number | null
          payer_id: string | null
          plan_id: string | null
          price_tiyin: number | null
          seq: number | null
          state: string | null
          student_id: string | null
          subscription_id: string | null
          updated_at: string | null
        }
        Relationships: [
          {
            foreignKeyName: "installments_center_id_fkey"
            columns: ["center_id"]
            isOneToOne: false
            referencedRelation: "centers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "installments_plan_fk"
            columns: [
              "plan_id",
              "subscription_id",
              "student_id",
              "payer_id",
              "center_id",
            ]
            isOneToOne: false
            referencedRelation: "installment_plans"
            referencedColumns: [
              "id",
              "subscription_id",
              "student_id",
              "payer_id",
              "center_id",
            ]
          },
          {
            foreignKeyName: "installments_student_payer_fk"
            columns: ["student_id", "payer_id", "center_id"]
            isOneToOne: false
            referencedRelation: "student_payers"
            referencedColumns: ["student_id", "payer_id", "center_id"]
          },
          {
            foreignKeyName: "installments_subscription_fk"
            columns: ["subscription_id", "student_id", "center_id"]
            isOneToOne: false
            referencedRelation: "subscriptions"
            referencedColumns: ["id", "student_id", "center_id"]
          },
        ]
      }
      payers_with_stats: {
        Row: {
          center_id: string | null
          children_count: number | null
          created_at: string | null
          email: string | null
          full_name: string | null
          id: string | null
          notes: string | null
          phone: string | null
          phone_alt: string | null
          relation: string | null
        }
        Insert: {
          center_id?: string | null
          children_count?: never
          created_at?: string | null
          email?: string | null
          full_name?: string | null
          id?: string | null
          notes?: string | null
          phone?: string | null
          phone_alt?: string | null
          relation?: string | null
        }
        Update: {
          center_id?: string | null
          children_count?: never
          created_at?: string | null
          email?: string | null
          full_name?: string | null
          id?: string | null
          notes?: string | null
          phone?: string | null
          phone_alt?: string | null
          relation?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "payers_center_id_fkey"
            columns: ["center_id"]
            isOneToOne: false
            referencedRelation: "centers"
            referencedColumns: ["id"]
          },
        ]
      }
      pending_invitations_view: {
        Row: {
          center_id: string | null
          created_at: string | null
          email: string | null
          expires_at: string | null
          full_name: string | null
          id: string | null
          phone: string | null
          role: string | null
          teacher_id: string | null
          token: string | null
        }
        Relationships: [
          {
            foreignKeyName: "invitations_center_id_fkey"
            columns: ["center_id"]
            isOneToOne: false
            referencedRelation: "centers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invitations_teacher_fk"
            columns: ["teacher_id", "center_id"]
            isOneToOne: false
            referencedRelation: "teachers"
            referencedColumns: ["id", "center_id"]
          },
        ]
      }
      revenue_by_month: {
        Row: {
          center_id: string | null
          lessons: number | null
          month: string | null
          revenue_tiyin: number | null
          unlimited_visits: number | null
          unpriced_visits: number | null
          visits: number | null
        }
        Relationships: []
      }
      revenue_by_service: {
        Row: {
          center_id: string | null
          lessons: number | null
          month: string | null
          revenue_tiyin: number | null
          service_id: string | null
          unlimited_visits: number | null
          unpriced_visits: number | null
          visits: number | null
        }
        Relationships: []
      }
      revenue_by_teacher: {
        Row: {
          center_id: string | null
          lessons: number | null
          month: string | null
          revenue_tiyin: number | null
          teacher_id: string | null
          unlimited_visits: number | null
          unpriced_visits: number | null
          visits: number | null
        }
        Relationships: []
      }
      staff_view: {
        Row: {
          center_id: string | null
          email: string | null
          full_name: string | null
          is_active: boolean | null
          joined_at: string | null
          role: string | null
          teacher_id: string | null
          user_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "memberships_center_id_fkey"
            columns: ["center_id"]
            isOneToOne: false
            referencedRelation: "centers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "memberships_teacher_fk"
            columns: ["teacher_id", "center_id"]
            isOneToOne: false
            referencedRelation: "teachers"
            referencedColumns: ["id", "center_id"]
          },
        ]
      }
      student_balance: {
        Row: {
          active_subscription_id: string | null
          center_id: string | null
          debt_tiyin: number | null
          ends_at: string | null
          lessons_left: number | null
          overdrawn_tiyin: number | null
          state: string | null
          student_id: string | null
        }
        Relationships: []
      }
      students_teacher_view: {
        Row: {
          age_years: number | null
          birth_date: string | null
          center_id: string | null
          full_name: string | null
          gender: string | null
          id: string | null
          notes: string | null
          payer_full_name: string | null
          primary_teacher_id: string | null
          status: string | null
        }
        Insert: {
          age_years?: never
          birth_date?: string | null
          center_id?: string | null
          full_name?: string | null
          gender?: string | null
          id?: string | null
          notes?: string | null
          payer_full_name?: never
          primary_teacher_id?: string | null
          status?: string | null
        }
        Update: {
          age_years?: never
          birth_date?: string | null
          center_id?: string | null
          full_name?: string | null
          gender?: string | null
          id?: string | null
          notes?: string | null
          payer_full_name?: never
          primary_teacher_id?: string | null
          status?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "students_center_id_fkey"
            columns: ["center_id"]
            isOneToOne: false
            referencedRelation: "centers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "students_primary_teacher_fk"
            columns: ["primary_teacher_id", "center_id"]
            isOneToOne: false
            referencedRelation: "teachers"
            referencedColumns: ["id", "center_id"]
          },
        ]
      }
    }
    Functions: {
      accept_invitation: { Args: { p_token: string }; Returns: string }
      ack_events: { Args: { p_ids: number[] }; Returns: number }
      age_years: { Args: { p_birth_date: string }; Returns: number }
      approve_salary: {
        Args: { p_month: string; p_teacher_id: string }
        Returns: string
      }
      archive_attendance_status: { Args: { p_id: string }; Returns: undefined }
      archive_expense_category: { Args: { p_id: string }; Returns: undefined }
      archive_payment_source: { Args: { p_id: string }; Returns: undefined }
      archive_student: { Args: { p_id: string }; Returns: undefined }
      archive_subscription_type: { Args: { p_id: string }; Returns: undefined }
      archive_teacher: { Args: { p_id: string }; Returns: undefined }
      backfill_student_payers_history: { Args: never; Returns: undefined }
      backfill_subscription_payments: { Args: never; Returns: undefined }
      bot_balance: {
        Args: { p_chat_id: number }
        Returns: {
          center_name: string
          debt_tiyin: number
          full_name: string
          has_subscription: boolean
          lessons_left: number
          student_id: string
        }[]
      }
      bot_today: {
        Args: { p_chat_id: number }
        Returns: {
          center_id: string
          center_name: string
          lesson_id: string
          starts_at: string
          teacher_name: string
          title: string
        }[]
      }
      calc_lesson_price: {
        Args: { p_lessons: number; p_price_tiyin: number }
        Returns: number
      }
      calc_salary: {
        Args: { p_month: string; p_teacher_id: string }
        Returns: {
          amount_tiyin: number
          attendance_id: string
          lesson_date: string
          lesson_id: string
          lesson_price_tiyin: number
          model: string
          note: string
          student_id: string
        }[]
      }
      can_finance: { Args: { p_center_id?: string }; Returns: boolean }
      can_front_desk: { Args: { p_center_id?: string }; Returns: boolean }
      can_payments: { Args: { p_center_id?: string }; Returns: boolean }
      cancel_installment_plan: {
        Args: { p_subscription_id: string }
        Returns: number
      }
      cancel_lesson: {
        Args: { p_id: string; p_reason?: string }
        Returns: undefined
      }
      cancel_salary_run: {
        Args: { p_month: string; p_teacher_id: string }
        Returns: string
      }
      cancel_series_from: {
        Args: { p_from: string; p_reason?: string; p_series_id: string }
        Returns: number
      }
      center_timezone: { Args: { p_center_id?: string }; Returns: string }
      center_today: { Args: { p_center_id?: string }; Returns: string }
      change_member_role: {
        Args: { p_role: string; p_user_id: string }
        Returns: undefined
      }
      check_absent_streak: {
        Args: { p_center: string; p_lesson: string; p_student: string }
        Returns: undefined
      }
      claim_events: {
        Args: { p_limit?: number }
        Returns: {
          attempts: number
          center_id: string
          created_at: string
          id: number
          payload: Json
          type: string
        }[]
      }
      clinical_goal_visible: { Args: { p_goal_id: string }; Returns: boolean }
      clinical_homework_visible: {
        Args: { p_homework_id: string }
        Returns: boolean
      }
      clinical_role_allowed: { Args: { p_role: string }; Returns: boolean }
      clinical_teacher_sees: {
        Args: { p_student_id: string }
        Returns: boolean
      }
      clinical_visible_to_caller: {
        Args: { p_student_id: string }
        Returns: boolean
      }
      close_month: { Args: { p_month: string }; Returns: undefined }
      confirm_lesson: {
        Args: { p_chat_id: number; p_lesson_id: string; p_student_id: string }
        Returns: boolean
      }
      confirm_lesson_by_event: {
        Args: { p_chat_id: number; p_event_id: number; p_student_id: string }
        Returns: boolean
      }
      create_center: {
        Args: { p_city?: string; p_name: string }
        Returns: string
      }
      create_installment_plan: {
        Args: {
          p_expected_remaining_tiyin?: number
          p_first_due?: string
          p_n: number
          p_step_months?: number
          p_subscription_id: string
        }
        Returns: {
          amount_tiyin: number
          base_paid_tiyin: number
          cancelled_at: string
          center_id: string
          created_at: string
          cumulative_tiyin: number
          due_date: string
          due_notified_at: string
          id: string
          overdue_notified_at: string
          paid_tiyin: number
          payer_id: string
          plan_id: string
          price_tiyin: number
          seq: number
          state: string
          student_id: string
          subscription_id: string
          updated_at: string
        }[]
      }
      create_invitation: {
        Args: {
          p_email?: string
          p_full_name?: string
          p_phone?: string
          p_role: string
          p_teacher_id?: string
        }
        Returns: {
          invitation_id: string
          teacher_id: string
          token: string
        }[]
      }
      create_lesson_series: {
        Args: { p: Json }
        Returns: {
          lesson_id: string
          starts_at: string
        }[]
      }
      create_lesson_series_preview: {
        Args: { p: Json }
        Returns: {
          conflicts: Json
          day: string
          ends_at: string
          starts_at: string
        }[]
      }
      create_student_with_payer: {
        Args: {
          p_birth_date?: string
          p_full_name: string
          p_gender?: string
          p_notes?: string
          p_payer_full_name?: string
          p_payer_id?: string
          p_payer_phone?: string
          p_payer_relation?: string
          p_primary_teacher_id?: string
          p_source?: string
        }
        Returns: {
          payer_id: string
          student_id: string
        }[]
      }
      create_telegram_link_code: { Args: never; Returns: string }
      current_center: { Args: never; Returns: string }
      daily_digest: {
        Args: never
        Returns: {
          center_count: number
        }[]
      }
      emit_event: {
        Args: { p_center_id?: string; p_payload?: Json; p_type: string }
        Returns: number
      }
      emit_event_unchecked: {
        Args: { p_center_id: string; p_payload: Json; p_type: string }
        Returns: number
      }
      event_messages: {
        Args: { p_event_id: number }
        Returns: {
          action: Json
          channel: string
          chat_id: number
          message: string
          recipient_user_id: string
          subject_id: string
        }[]
      }
      fail_events: {
        Args: { p_error?: string; p_ids: number[] }
        Returns: number
      }
      find_payer_by_phone: {
        Args: { p_phone: string }
        Returns: {
          children_count: number
          full_name: string
          id: string
          phone: string
          relation: string
        }[]
      }
      format_som: { Args: { p_tiyin: number }; Returns: string }
      freeze_subscription: {
        Args: { p_from: string; p_id: string; p_to?: string }
        Returns: undefined
      }
      has_feature: { Args: { p_feature: string }; Returns: boolean }
      installment_plans_cancel_live: {
        Args: { p_subscription_id: string }
        Returns: number
      }
      installments_notify: {
        Args: never
        Returns: {
          due_count: number
          overdue_count: number
        }[]
      }
      invitation_preview: {
        Args: { p_token: string }
        Returns: {
          center_name: string
          role: string
          valid: boolean
        }[]
      }
      is_member: { Args: { p_center_id: string }; Returns: boolean }
      lesson_reminders: {
        Args: never
        Returns: {
          sent_count: number
        }[]
      }
      lesson_slot_conflicts: {
        Args: {
          p_center: string
          p_ends: string
          p_exclude_id?: string
          p_group: string
          p_room: string
          p_starts: string
          p_student: string
          p_teacher: string
        }
        Returns: Json
      }
      link_telegram: {
        Args: { p_chat_id: number; p_code: string }
        Returns: string
      }
      mark_attendance: {
        Args: {
          p_comment?: string
          p_lesson_id: string
          p_status_code?: string
          p_student_id: string
        }
        Returns: string
      }
      mark_attendance_bulk: {
        Args: { p: Json; p_lesson_id: string }
        Returns: number
      }
      mark_lesson_status: {
        Args: { p_lesson_id: string; p_notes?: string; p_status: string }
        Returns: undefined
      }
      month_open_lessons_count: { Args: { p_month: string }; Returns: number }
      my_payer_id: { Args: never; Returns: string }
      my_role: { Args: never; Returns: string }
      my_teacher_id: { Args: never; Returns: string }
      normalize_kg_phone: { Args: { p_phone: string }; Returns: string }
      notification_admin_targets: {
        Args: { p_center_id: string; p_event_type: string }
        Returns: {
          channel: string
          chat_id: number
          template_text: string
          user_id: string
        }[]
      }
      notification_begin: {
        Args: {
          p_channel: string
          p_event_id: number
          p_recipient: string
          p_subject_id?: string
        }
        Returns: string
      }
      notification_finish: {
        Args: {
          p_error?: string
          p_id: string
          p_status: string
          p_text?: string
        }
        Returns: boolean
      }
      notification_skip: {
        Args: { p_event_id: number; p_reason: string }
        Returns: string
      }
      notification_targets: {
        Args: { p_center_id: string; p_event_type: string; p_payer_id: string }
        Returns: {
          channel: string
          chat_id: number
          template_text: string
          user_id: string
        }[]
      }
      parent_of_lesson: { Args: { p_lesson_id: string }; Returns: boolean }
      parent_of_student: { Args: { p_student_id: string }; Returns: boolean }
      pay_installment: {
        Args: {
          p_comment?: string
          p_installment_id: string
          p_paid_at?: string
          p_source_id?: string
        }
        Returns: string
      }
      payer_display_name: { Args: { p_payer_id: string }; Returns: string }
      payer_telegram_linked: { Args: { p_payer_id: string }; Returns: boolean }
      payers_brief: {
        Args: never
        Returns: {
          center_id: string
          created_at: string
          email: string
          full_name: string
          id: string
          phone: string
          phone_alt: string
          relation: string
        }[]
      }
      preview_message: {
        Args: { p_text: string; p_vars?: Json }
        Returns: string
      }
      rebuild_lesson_participants: {
        Args: { p_lesson_id: string }
        Returns: undefined
      }
      recalc_subscription_paid: {
        Args: { p_subscription_id: string }
        Returns: undefined
      }
      recalc_subscription_usage: {
        Args: { p_subscription_id: string }
        Returns: undefined
      }
      record_expense: {
        Args: {
          p_amount_tiyin: number
          p_category_id: string
          p_comment?: string
          p_kind?: string
          p_paid_on?: string
          p_source_id?: string
        }
        Returns: string
      }
      record_payment: {
        Args: {
          p_amount_tiyin: number
          p_comment?: string
          p_kind?: string
          p_paid_at?: string
          p_paid_on?: string
          p_payer_id: string
          p_source_id?: string
          p_student_id?: string
          p_subscription_id?: string
        }
        Returns: string
      }
      record_salary_adjustment: {
        Args: {
          p_amount_tiyin: number
          p_month: string
          p_reason: string
          p_teacher_id: string
        }
        Returns: string
      }
      refund_calc: { Args: { p_id: string }; Returns: number }
      refund_subscription: {
        Args: { p_expected_tiyin: number; p_id: string; p_source_id?: string }
        Returns: number
      }
      release_stale_claims: { Args: { p_older_than?: string }; Returns: number }
      render_template: {
        Args: { p_text: string; p_vars: Json }
        Returns: string
      }
      reopen_month: { Args: { p_month: string }; Returns: undefined }
      repair_center_scoped_refs: { Args: never; Returns: undefined }
      reschedule_lesson: {
        Args: { p_ends_at: string; p_lesson_id: string; p_starts_at: string }
        Returns: undefined
      }
      reset_message_template: {
        Args: { p_channel: string; p_event_type: string }
        Returns: boolean
      }
      resolve_template: {
        Args: { p_center_id: string; p_channel: string; p_event_type: string }
        Returns: {
          message_text: string
          should_send: boolean
        }[]
      }
      restore_attendance_status: { Args: { p_id: string }; Returns: undefined }
      restore_expense_category: { Args: { p_id: string }; Returns: undefined }
      restore_payment_source: { Args: { p_id: string }; Returns: undefined }
      restore_student: { Args: { p_id: string }; Returns: undefined }
      restore_subscription_type: { Args: { p_id: string }; Returns: undefined }
      restore_teacher: { Args: { p_id: string }; Returns: undefined }
      revenue_facts: {
        Args: never
        Returns: {
          center_id: string
          lesson_id: string
          paid_teacher_id: string
          price_tiyin: number
          service_id: string
          starts_at: string
          subscription_id: string
        }[]
      }
      revoke_membership: { Args: { p_user_id: string }; Returns: undefined }
      role_in: { Args: { p_center_id: string }; Returns: string }
      ru_month_year: { Args: { p_date: string }; Returns: string }
      salary_summary: {
        Args: { p_month: string }
        Returns: {
          adjustments_tiyin: number
          approved_at: string
          approved_run_id: string
          calc_tiyin: number
          cancelled_runs: number
          teacher_id: string
          total_tiyin: number
        }[]
      }
      seed_attendance_statuses: {
        Args: { p_center_id: string }
        Returns: undefined
      }
      seed_expense_categories: {
        Args: { p_center_id: string }
        Returns: undefined
      }
      seed_goal_stages: { Args: { p_center_id: string }; Returns: undefined }
      seed_payment_sources: {
        Args: { p_center_id: string }
        Returns: undefined
      }
      sell_subscription: {
        Args: {
          p_price_tiyin?: number
          p_starts_at?: string
          p_student_id: string
          p_type_id: string
        }
        Returns: string
      }
      sell_subscription_paid: {
        Args: {
          p_expected_remaining_tiyin?: number
          p_first_due?: string
          p_installments?: number
          p_paid_on?: string
          p_paid_tiyin?: number
          p_price_tiyin?: number
          p_sale_key: string
          p_source_id?: string
          p_starts_at?: string
          p_step_months?: number
          p_student_id: string
          p_type_id: string
        }
        Returns: {
          amount_tiyin: number
          due_date: string
          payment_id: string
          seq: number
          subscription_id: string
        }[]
      }
      series_dates: {
        Args: { p: Json }
        Returns: {
          day: string
          ends_at: string
          starts_at: string
        }[]
      }
      set_default_attendance_status: {
        Args: { p_id: string }
        Returns: undefined
      }
      slugify: { Args: { p_text: string }; Returns: string }
      student_balance_pick: {
        Args: { p_student_id: string }
        Returns: {
          ends_at: string
          lesson_price_tiyin: number
          state: string
          subscription_id: string
        }[]
      }
      student_debts: {
        Args: never
        Returns: {
          debt_tiyin: number
          student_id: string
        }[]
      }
      student_diagnostics_brief: {
        Args: { p_student_id: string }
        Returns: {
          conclusion: string
          date: string
          id: string
          teacher_name: string
        }[]
      }
      student_goals_brief: {
        Args: { p_student_id: string }
        Returns: {
          area: string
          id: string
          last_score: number
          sound: string
          stage_sort: number
          stage_title: string
          status: string
          target_date: string
          title: string
        }[]
      }
      student_notes_brief: {
        Args: { p_student_id: string }
        Returns: {
          id: string
          lesson_at: string
          lesson_id: string
          parent_summary: string
        }[]
      }
      student_subscription_badge: {
        Args: { p_student_id: string }
        Returns: string
      }
      students_brief: {
        Args: never
        Returns: {
          birth_date: string
          center_id: string
          created_at: string
          full_name: string
          id: string
          payer_id: string
          primary_teacher_id: string
          status: string
        }[]
      }
      subscription_current_freeze: {
        Args: { p_on_date?: string; p_subscription_id: string }
        Returns: unknown
      }
      subscription_freeze_days: {
        Args: { p_subscription_id: string }
        Returns: number
      }
      subscription_freeze_days_unchecked: {
        Args: { p_subscription_id: string }
        Returns: number
      }
      subscription_lessons_left: {
        Args: { p_subscription_id: string }
        Returns: number
      }
      subscription_payment_summary: {
        Args: { p_subscription_id: string }
        Returns: {
          installments_total: number
          installments_unpaid: number
          next_due: string
          overdue_count: number
          paid_tiyin: number
          payment_state: string
          price_tiyin: number
        }[]
      }
      subscription_state: {
        Args: { p_subscription_id: string }
        Returns: string
      }
      subscription_state_unchecked: {
        Args: { p_subscription_id: string }
        Returns: string
      }
      subscription_summary: {
        Args: { p_subscription_id: string }
        Returns: {
          allow_negative: boolean
          freeze_days: number
          freeze_from: string
          freeze_to: string
          lessons_left: number
          refund_tiyin: number
          state: string
        }[]
      }
      subscription_visible_to_caller: {
        Args: { p_subscription_id: string }
        Returns: boolean
      }
      substitute_teacher: {
        Args: { p_lesson_id: string; p_new_teacher_id: string }
        Returns: undefined
      }
      switch_center: { Args: { p_center_id: string }; Returns: undefined }
      teacher_of_lesson: { Args: { p_lesson_id: string }; Returns: boolean }
      teacher_teaches_student: {
        Args: { p_student_id: string }
        Returns: boolean
      }
      teacher_vacation: {
        Args: { p_from: string; p_teacher_id: string; p_to: string }
        Returns: number
      }
      teacher_vacation_preview: {
        Args: { p_from: string; p_teacher_id: string; p_to: string }
        Returns: {
          as_substitute: boolean
          lesson_id: string
          starts_at: string
        }[]
      }
      telegram_user: { Args: { p_chat_id: number }; Returns: string }
      transfer_remaining: {
        Args: { p_from: string; p_to_student: string }
        Returns: string
      }
      unfreeze_subscription: {
        Args: { p_id: string; p_to?: string }
        Returns: undefined
      }
      unlink_telegram: { Args: never; Returns: boolean }
      upsert_message_template: {
        Args: {
          p_channel: string
          p_event_type: string
          p_is_active: boolean
          p_text: string
        }
        Returns: string
      }
      user_email: { Args: { p_user_id: string }; Returns: string }
      was_access_revoked: { Args: never; Returns: boolean }
    }
    Enums: {
      [_ in never]: never
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {},
  },
} as const

