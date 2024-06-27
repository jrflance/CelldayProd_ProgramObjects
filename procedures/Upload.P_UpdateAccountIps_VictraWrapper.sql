--liquibase formatted sql

--changeset  BrandonStahl:3bd8b369-4f98-403d-a6da-1d09a8dcbd48 stripComments:false runOnChange:true splitStatements:false

-- =============================================
-- Author:		Brandon Stahl
-- Create date: 2024-06-19
-- Description: Victra wrapper temp solution until data upload v2 is completed.
-- =============================================
CREATE OR ALTER PROCEDURE [upload].[P_UpdateAccountIps_VictraWrapper]
    (
        @FileId INT
    )
AS
BEGIN

    DECLARE @TopParentAccountId INT = 158286;
    EXECUTE Upload.P_UpdateAccountIps @TopParentAccountId, @FileId;

END;
