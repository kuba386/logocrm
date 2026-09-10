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
            referencedRelation: "student_balance"
            referencedColumns: ["student_id", "center_id"]
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
      events: {
        Row: {
          center_id: string
          created_at: string
          id: number
          payload: Json
          processed_at: string | null
          type: string
        }
        Insert: {
          center_id: string
          created_at?: string
          id?: number
          payload?: Json
          processed_at?: string | null
          type: string
        }
        Update: {
          center_id?: string
          created_at?: string
          id?: number
          payload?: Json
          processed_at?: string | null
          type?: string
        }
        Relationships: []
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
            foreignKeyName: "group_students_group_id_fkey"
            columns: ["group_id"]
            isOneToOne: false
            referencedRelation: "groups"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "group_students_student_id_fkey"
            columns: ["student_id"]
            isOneToOne: false
            referencedRelation: "student_balance"
            referencedColumns: ["student_id"]
          },
          {
            foreignKeyName: "group_students_student_id_fkey"
            columns: ["student_id"]
            isOneToOne: false
            referencedRelation: "students"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "group_students_student_id_fkey"
            columns: ["student_id"]
            isOneToOne: false
            referencedRelation: "students_teacher_view"
            referencedColumns: ["id"]
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
            foreignKeyName: "groups_room_id_fkey"
            columns: ["room_id"]
            isOneToOne: false
            referencedRelation: "rooms"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "groups_service_id_fkey"
            columns: ["service_id"]
            isOneToOne: false
            referencedRelation: "services"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "groups_teacher_id_fkey"
            columns: ["teacher_id"]
            isOneToOne: false
            referencedRelation: "teachers"
            referencedColumns: ["id"]
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
            foreignKeyName: "invitations_teacher_id_fkey"
            columns: ["teacher_id"]
            isOneToOne: false
            referencedRelation: "teachers"
            referencedColumns: ["id"]
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
            foreignKeyName: "lesson_participants_lesson_id_fkey"
            columns: ["lesson_id"]
            isOneToOne: false
            referencedRelation: "lessons"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "lesson_participants_student_id_fkey"
            columns: ["student_id"]
            isOneToOne: false
            referencedRelation: "student_balance"
            referencedColumns: ["student_id"]
          },
          {
            foreignKeyName: "lesson_participants_student_id_fkey"
            columns: ["student_id"]
            isOneToOne: false
            referencedRelation: "students"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "lesson_participants_student_id_fkey"
            columns: ["student_id"]
            isOneToOne: false
            referencedRelation: "students_teacher_view"
            referencedColumns: ["id"]
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
            foreignKeyName: "lessons_group_id_fkey"
            columns: ["group_id"]
            isOneToOne: false
            referencedRelation: "groups"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "lessons_room_id_fkey"
            columns: ["room_id"]
            isOneToOne: false
            referencedRelation: "rooms"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "lessons_service_id_fkey"
            columns: ["service_id"]
            isOneToOne: false
            referencedRelation: "services"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "lessons_student_id_fkey"
            columns: ["student_id"]
            isOneToOne: false
            referencedRelation: "student_balance"
            referencedColumns: ["student_id"]
          },
          {
            foreignKeyName: "lessons_student_id_fkey"
            columns: ["student_id"]
            isOneToOne: false
            referencedRelation: "students"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "lessons_student_id_fkey"
            columns: ["student_id"]
            isOneToOne: false
            referencedRelation: "students_teacher_view"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "lessons_substitute_teacher_id_fkey"
            columns: ["substitute_teacher_id"]
            isOneToOne: false
            referencedRelation: "teachers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "lessons_teacher_id_fkey"
            columns: ["teacher_id"]
            isOneToOne: false
            referencedRelation: "teachers"
            referencedColumns: ["id"]
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
            referencedRelation: "students"
            referencedColumns: ["id", "payer_id", "center_id"]
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
            foreignKeyName: "students_payer_id_fkey"
            columns: ["payer_id"]
            isOneToOne: false
            referencedRelation: "payers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "students_payer_id_fkey"
            columns: ["payer_id"]
            isOneToOne: false
            referencedRelation: "payers_with_stats"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "students_primary_teacher_id_fkey"
            columns: ["primary_teacher_id"]
            isOneToOne: false
            referencedRelation: "teachers"
            referencedColumns: ["id"]
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
            referencedRelation: "student_balance"
            referencedColumns: ["student_id", "center_id"]
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
    }
    Views: {
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
            foreignKeyName: "invitations_teacher_id_fkey"
            columns: ["teacher_id"]
            isOneToOne: false
            referencedRelation: "teachers"
            referencedColumns: ["id"]
          },
        ]
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
        Relationships: [
          {
            foreignKeyName: "students_center_id_fkey"
            columns: ["center_id"]
            isOneToOne: false
            referencedRelation: "centers"
            referencedColumns: ["id"]
          },
        ]
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
            foreignKeyName: "students_primary_teacher_id_fkey"
            columns: ["primary_teacher_id"]
            isOneToOne: false
            referencedRelation: "teachers"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Functions: {
      accept_invitation: { Args: { p_token: string }; Returns: string }
      age_years: { Args: { p_birth_date: string }; Returns: number }
      archive_attendance_status: { Args: { p_id: string }; Returns: undefined }
      archive_payment_source: { Args: { p_id: string }; Returns: undefined }
      archive_student: { Args: { p_id: string }; Returns: undefined }
      archive_subscription_type: { Args: { p_id: string }; Returns: undefined }
      calc_lesson_price: {
        Args: { p_lessons: number; p_price_tiyin: number }
        Returns: number
      }
      cancel_lesson: {
        Args: { p_id: string; p_reason?: string }
        Returns: undefined
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
      close_month: { Args: { p_month: string }; Returns: undefined }
      create_center: {
        Args: { p_city?: string; p_name: string }
        Returns: string
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
      current_center: { Args: never; Returns: string }
      emit_event: {
        Args: { p_center_id?: string; p_payload?: Json; p_type: string }
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
      freeze_subscription: {
        Args: { p_from: string; p_id: string; p_to?: string }
        Returns: undefined
      }
      has_feature: { Args: { p_feature: string }; Returns: boolean }
      invitation_preview: {
        Args: { p_token: string }
        Returns: {
          center_name: string
          role: string
          valid: boolean
        }[]
      }
      is_member: { Args: { p_center_id: string }; Returns: boolean }
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
      my_payer_id: { Args: never; Returns: string }
      my_role: { Args: never; Returns: string }
      my_teacher_id: { Args: never; Returns: string }
      normalize_kg_phone: { Args: { p_phone: string }; Returns: string }
      parent_of_lesson: { Args: { p_lesson_id: string }; Returns: boolean }
      parent_of_student: { Args: { p_student_id: string }; Returns: boolean }
      payer_display_name: { Args: { p_payer_id: string }; Returns: string }
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
      record_payment: {
        Args: {
          p_amount_tiyin: number
          p_comment?: string
          p_kind?: string
          p_paid_at?: string
          p_payer_id: string
          p_source_id?: string
          p_student_id?: string
          p_subscription_id?: string
        }
        Returns: string
      }
      refund_calc: { Args: { p_id: string }; Returns: number }
      refund_subscription: {
        Args: { p_expected_tiyin: number; p_id: string }
        Returns: number
      }
      reopen_month: { Args: { p_month: string }; Returns: undefined }
      reschedule_lesson: {
        Args: { p_ends_at: string; p_lesson_id: string; p_starts_at: string }
        Returns: undefined
      }
      restore_attendance_status: { Args: { p_id: string }; Returns: undefined }
      restore_payment_source: { Args: { p_id: string }; Returns: undefined }
      restore_student: { Args: { p_id: string }; Returns: undefined }
      restore_subscription_type: { Args: { p_id: string }; Returns: undefined }
      revoke_membership: { Args: { p_user_id: string }; Returns: undefined }
      role_in: { Args: { p_center_id: string }; Returns: string }
      seed_attendance_statuses: {
        Args: { p_center_id: string }
        Returns: undefined
      }
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
      student_subscription_badge: {
        Args: { p_student_id: string }
        Returns: string
      }
      subscription_current_freeze: {
        Args: { p_on_date: string; p_subscription_id: string }
        Returns: unknown
      }
      subscription_freeze_days: {
        Args: { p_subscription_id: string }
        Returns: number
      }
      subscription_lessons_left: {
        Args: { p_subscription_id: string }
        Returns: number
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
      transfer_remaining: {
        Args: { p_from: string; p_to_student: string }
        Returns: string
      }
      unfreeze_subscription: {
        Args: { p_id: string; p_to?: string }
        Returns: undefined
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

