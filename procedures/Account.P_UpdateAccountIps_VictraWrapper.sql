--liquibase formatted sql

--changeset  BrandonStahl:3bd8b369-4f98-403d-a6da-1d09a8dcbd48 stripComments:false runOnChange:true splitStatements:false

-- =============================================
-- Author:		Brandon Stahl
-- Create date: 2024-06-19
-- Description: Victra wrapper temp solution until data upload v2 is completed.
-- =============================================
CREATE OR ALTER PROCEDURE [Account].[P_UpdateAccountIps_VictraWrapper]
    (
        @FileId INT
    )
AS
BEGIN
    BEGIN TRY
        SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
        DECLARE
            @Separator VARCHAR(8),
            @TextDelimiter VARCHAR(8) = '"',
            @TopParentAccountId INT = 158286;
        SELECT
            @Separator = ft.Delimiter,
            @TextDelimiter = ft.ROWDelimiter
        FROM upload.tblFileType AS ft
        JOIN upload.tblFile AS f
            ON f.FileTypeID = ft.FileTypeID
        WHERE f.FileID = @FileID;

        TRUNCATE TABLE CellDayTemp.Upload.tblOutPutFile;
        INSERT INTO CellDayTemp.Upload.tblOutPutFile
        (
            Output
        )
        VALUES
        (
            -- noqa: disable=all
            'AccountId,Status,Message'
            -- noqa: enable=all
        );

        DROP TABLE IF EXISTS #final;

        CREATE TABLE #final
        (
            AccountId VARCHAR(100),
            IPAddresses VARCHAR(500),
            [Status] VARCHAR(100),
            [Message] VARCHAR(100)
        );

        EXECUTE Account.P_UpdateAccountIps @TopParentAccountId;

        WITH CTEFinal AS (
            SELECT
                CONVERT(
                    VARCHAR(8000),
                    Tracfone.fnEdiRows(
                        @Separator,
                        '',
                        '',
                        AccountId,
                        IPAddresses,
                        [Status],
                        -- noqa: disable=all
                        [Message],
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT
                    -- noqa: enable=all
                    )
                ) AS PlainText
            FROM #final AS SUB
        )
        INSERT INTO upload.OutPutFile
        (
            Output
        )
        SELECT PlainText
        FROM CTEFinal AS SUB;


        DROP TABLE #final;
        DECLARE
            @CNT INT =
            (
                SELECT COUNT(1) FROM CellDayTemp.Upload.tblOutPutFile
            );

        SELECT @CNT AS RecordCount;
    END TRY
    BEGIN CATCH
        DECLARE
            @ERRMSG VARCHAR(200) =
            (
                SELECT ERROR_MESSAGE()
            );

        UPDATE f
        SET
            f.FileStatus = -1,
            f.ErrorInfo = @ERRMSG
        FROM upload.tblFile AS f
        WHERE FileID = @FileID

        SELECT 0 AS RecordCount
        ; THROW;
    END CATCH
END;
