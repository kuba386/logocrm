// Сгенерировано: supabase gen types typescript --schema public
// Проект: logocrm (hiwstqrnxrlfuanvfggq). Перегенерировать после каждой миграции:
//   pnpm db:types
// Файл коммитится в репозиторий — на него опирается typecheck в CI.
//
// Канонический вариант производит CLI из миграций (джоб «База данных» в CI
// выкладывает его артефактом database-types). Генератор из облака даёт тот же
// набор таблиц, но иначе форматирует дженерики и добавляет __InternalSupabase —
// при расхождении берите файл из артефакта, а не правьте руками.

export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.5"
  }
  public: {
    Tables: {
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
      archive_student: { Args: { p_id: string }; Returns: undefined }
      change_member_role: {
        Args: { p_role: string; p_user_id: string }
        Returns: undefined
      }
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
      my_payer_id: { Args: never; Returns: string }
      my_role: { Args: never; Returns: string }
      my_teacher_id: { Args: never; Returns: string }
      normalize_kg_phone: { Args: { p_phone: string }; Returns: string }
      payer_display_name: { Args: { p_payer_id: string }; Returns: string }
      restore_student: { Args: { p_id: string }; Returns: undefined }
      revoke_membership: { Args: { p_user_id: string }; Returns: undefined }
      role_in: { Args: { p_center_id: string }; Returns: string }
      slugify: { Args: { p_text: string }; Returns: string }
      switch_center: { Args: { p_center_id: string }; Returns: undefined }
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
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never) = never,
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
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
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
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
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
  EnumName extends (DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never) = never,
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
  CompositeTypeName extends (PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never) = never,
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
