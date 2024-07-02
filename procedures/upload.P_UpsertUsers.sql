--liquibase formatted sql

--changeset  BrandonStahl:4313f452-1479-4d06-b412-7d6be78b35a4 stripComments:false runOnChange:true splitStatements:false

-- =============================================
-- Author:		Brandon Stahl
-- Create date: 2024-06-24
-- Description: Upload file to landing table SSIS job.
-- =============================================
CREATE OR ALTER PROCEDURE [upload].[P_UpsertUsers]
    (
        @TopParentAccountId INT,
        @FileId INT
    )
AS
BEGIN
    BEGIN TRY
        SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
        DECLARE @FileTypeID INT = (SELECT TOP 1 FileTypeId FROM Upload.tblFile WHERE FileID = @FileID);

        DECLARE
            @Delimiter VARCHAR(8) =
            (
                SELECT u.Delimiter
                FROM upload.tblFileType AS u
                WHERE u.FileTypeID = @FileTypeID
            );

        DELETE uu
        FROM Upload.tblUploadUsers AS uu
        WHERE uu.ProcessAccountId = @TopParentAccountId

        BEGIN TRANSACTION
        INSERT INTO Upload.tblUploadUsers
        (
            SourceUserId,
            SourceUserName,
            FirstName,
            LastName,
            Email,
            UserType,
            LocationId,
            Change,
            AccountId,
            ProcessAccountId
        )
        SELECT
            TRIM(A.Chr1) AS SourceUserId,
            TRIM(A.Chr2) AS SourceUserName,
            TRIM(A.Chr3) AS FirstName,
            TRIM(A.Chr4) AS LastName,
            TRIM(A.Chr5) AS Email,
            TRIM(A.Chr6) AS UserType,
            TRIM(A.Chr7) AS LocationId,
            TRIM(A.Chr8) AS Change,
            TRIM(REPLACE(REPLACE(A.Chr9, CHAR(13), ''), CHAR(10), '')) AS AccountId,
            @TopParentAccountId AS ProcessAccountId
        FROM Upload.tblPlainTextFiles AS t
        CROSS APPLY dbo.SplitText(t.txt, @Delimiter, '"') AS A
        WHERE
            t.FileID = @FileID
            AND TRIM(A.Chr1) != 'SourceUserId';;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        ROLLBACK;
        DELETE uu
        FROM Upload.tblUploadUsers AS uu
        WHERE uu.ProcessAccountId = @TopParentAccountId
    END CATCH
END;
