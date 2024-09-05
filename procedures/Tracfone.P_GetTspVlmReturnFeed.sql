--liquibase formatted sql

--changeset jrose:E6C50A59-C7B7-4C02-8FCB-309CB34DD6CF stripComments:false runOnChange:true endDelimiter:/
-- =============================================
--             :
--      Author : John Rose
--             :
-- Create Date : 2024-07-18
--             :
-- Description : Base on [Tracfone].[P_GetDealerSignupReturnFeed]. This return feed
--             : pulls all TBV accounts from the Tracfone.tblDealerApprovedSignup table.
--             :
--       Usage : EXEC [Tracfone].[P_GetTspVlmReturnFeed]
--             :
--             : select newid()
-- =============================================
-- noqa: disable=all
CREATE OR ALTER PROCEDURE [Tracfone].[P_GetTspVlmReturnFeed]
(
    @FileID INT = 0
)
-- noqa: enable=all
AS
BEGIN
    BEGIN TRY
        SET NOCOUNT ON

        DECLARE @Separator VARCHAR(8), @TextDelimiter VARCHAR(8)

        DROP TABLE IF EXISTS CTE

        SELECT
            @Separator = ft.Delimiter,
            @TextDelimiter = ft.ROWDelimiter
        FROM upload.tblFileType AS ft
            JOIN upload.tblFile AS f
                ON f.FileTypeID = ft.FileTypeID
        WHERE f.FileID = @FileID;

        TRUNCATE TABLE CellDayTemp.Upload.tblOutPutFile;

        ;WITH CTE AS (
            SELECT
                'TCETRA' AS [TSP],

                tar.Account_ID AS TSP_ID,
                tar.Account_ID AS [DAP_ID],

                gtr.First_Name AS [Principal_FirstName],
                gtr.Last_Name AS [Principal_LastName],
                gtr.Address AS [Principal_Address1],

                cus.Address2 AS [Principal_Address2],

                gtr.City AS [Principal_City],
                gtr.State AS [Principal_State],
                gtr.Zip AS [Principal_Zip],
                gtr.Phone AS [Principal_Phone],
                gtr.Email AS [Principal_Email],

                acc.Account_Name AS [Business_Name],
                cus.Address1 AS [Business_Address1],
                cus.Address2 AS [Business_Address2],
                cus.City AS [Business_City],
                cus.Zip AS [Business_Zip],
                cus.State AS [Business_State],

                dtm.AssignedMAAccountId AS [Master_Agent_ID],
                dtm.Master_ID AS [DAP_Trac_MA_ID],

                cus.Phone AS [Business_Phone],

                CASE WHEN tds.Status = 1
                THEN 'APPROVED'
                ELSE WHEN tds.Status = 2
                THEN 'PENDING'
                ELSE 'SUSPENDED'
                END 
                    AS [DEALER_STATUS],

                '100' AS [BUSINESS_STATUS_CODE],

                '' AS [Business_FEIN],

                '' AS [USPS_Business_Address],

                COALESCE(CONVERT(VARCHAR(20), trm.Root_ID), tar.Account_ID) AS [DAP_ACCOUNT_ID]

            FROM [Tracfone].[tblTracTSPAccountRegistration] AS tar WITH (NOLOCK)
            JOIN [Tracfone].[tblTracfoneDealerStatus] AS tds ON tds.TracfoneDealerStatusID = tar.TracfoneStatus
            JOIN [dbo].[Account] AS acc
                ON
                    tar.Account_ID = CONVERT(VARCHAR(20), acc.Account_ID)
                    AND (acc.IstestAccount IS NULL OR acc.IstestAccount <> 1)

            JOIN [dbo].[tblGuarantor] AS gtr ON tar.Account_ID = CONVERT(VARCHAR(20), gtr.Account_ID)
            JOIN [dbo].[Customers] AS cus ON acc.Customer_ID = cus.Customer_ID
            JOIN [dbo].[Users] AS usr ON cus.User_ID = usr.User_ID
            JOIN [Tracfone].[tblTspRootMapping] AS trm ON tar.Account_ID = CAST(trm.TSP_ID AS VARCHAR(20))

            LEFT JOIN [Tracfone].[tblDAPTracMA] AS dtm ON dtm.AssignedMAAccountId = dbo.fn_GetTopParentAccountID_NotTcetra_2(acc.Account_ID)

            UNION

            SELECT
                'TCETRA' AS [TSP],

                tar.Account_ID AS TSP_ID,
                tar.Account_ID AS [DAP_ID],

                gtr.First_Name AS [Principal_FirstName],
                gtr.Last_Name AS [Principal_LastName],
                gtr.Address AS [Principal_Address1],

                cus.Address2 AS [Principal_Address2],

                gtr.City AS [Principal_City],
                gtr.State AS [Principal_State],
                gtr.Zip AS [Principal_Zip],
                gtr.Phone AS [Principal_Phone],
                gtr.Email AS [Principal_Email],

                acc.Account_Name AS [Business_Name],
                cus.Address1 AS [Business_Address1],
                cus.Address2 AS [Business_Address2],
                cus.City AS [Business_City],
                cus.Zip AS [Business_Zip],
                cus.State AS [Business_State],

                dtm.AssignedMAAccountId AS [Master_Agent_ID],
                dtm.Master_ID AS [DAP_Trac_MA_ID],

                cus.Phone AS [Business_Phone],

                CASE WHEN tds.Status = 0
                THEN 'APPROVED'
                ELSE WHEN tds.Status = 1
                THEN 'PENDING'
                ELSE 'SUSPENDED'
                END 
                    AS [DEALER_STATUS],

                '100' AS [BUSINESS_STATUS_CODE],

                '' AS [Business_FEIN],

                '' AS [USPS_Business_Address],

                COALESCE(CONVERT(VARCHAR(20), trm.Root_ID), tar.Account_ID) AS [DAP_ACCOUNT_ID]

            FROM [Tracfone].[tblTracTSPAccountRegistration] AS tar WITH (NOLOCK)
            JOIN [Tracfone].[tblTracfoneDealerStatus] AS tds ON tds.TracfoneDealerStatusID = tar.TracfoneStatus
            JOIN [dbo].[Account] AS acc
                ON
                    tar.Account_ID = CONVERT(VARCHAR(20), acc.Account_ID)
                    AND (acc.IstestAccount IS NULL OR acc.IstestAccount <> 1)

            JOIN [dbo].[tblGuarantor] AS gtr ON tar.Account_ID = CONVERT(VARCHAR(20), gtr.Account_ID)
            JOIN [dbo].[Customers] AS cus ON acc.Customer_ID = cus.Customer_ID
            JOIN [dbo].[Users] AS usr ON cus.User_ID = usr.User_ID

            LEFT JOIN [Tracfone].[tblDAPTracMA] AS dtm ON dtm.AssignedMAAccountId = dbo.fn_GetTopParentAccountID_NotTcetra_2(acc.Account_ID)
            LEFT JOIN [Tracfone].[tblTspRootMapping] AS trm ON tar.Account_ID = CAST(trm.TSP_ID AS VARCHAR(20))

            WHERE tar.TracfoneTierId = 3
        )
        ,CTEFinal AS
        (
            SELECT CONVERT(VARCHAR(8000), ' ') AS PlainText -- noqa: CV11
            WHERE NOT EXISTS (SELECT 1 FROM CTE)
            UNION ALL
            SELECT
                CONVERT(VARCHAR(8000), Tracfone.fnEdiRows(@Separator, DEFAULT, DEFAULT, -- noqa: PRS, LT05, LT02, CV11
                    'TSP', 'TSP_ID', 'DAP_ID',
                    'Principal_FirstName', 'Principal_LastName', 'Principal_Address1', 'Principal_Address2',
                    'Principal_City', 'Principal_State', 'Principal_Zip', 'Principal_Phone', 'Principal_Email',
                    'Business_Name', 'Business_Address1', 'Business_Address2', 'Business_City', 'Business_Zip',
                    'Business_State', 'Master_Agent_Id', 'DAP_Trac_MA_ID', 'Business_Phone', 'DEALER_STATUS', 'BUSINESS_STATUS_CODE',
                    'Business_FEIN', 'USPS_Business_Address', 'DAP_ACCOUNT_ID', -- noqa: PRS
                    DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT,
                    DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT,
                    DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT,
                    DEFAULT
                )) AS PlainText
            UNION ALL
            SELECT
                REPLACE(CONVERT(VARCHAR(8000), Tracfone.fnEdiRows(@Separator, DEFAULT, DEFAULT, -- noqa: PRS, LT05, LT02, CV11
                    TSP, TSP_ID, DAP_ID,
                    Principal_FirstName, Principal_LastName, Principal_Address1, Principal_Address2,
                    Principal_City, Principal_State, Principal_Zip, Principal_Phone, Principal_Email,
                    Business_Name, Business_Address1, Business_Address2, Business_City, Business_Zip,
                    Business_State, Master_Agent_Id, DAP_Trac_MA_ID, Business_Phone, DEALER_STATUS, BUSINESS_STATUS_CODE,
                    Business_FEIN, USPS_Business_Address, DAP_ACCOUNT_ID, -- noqa: PRS
                    DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT,
                    DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT,
                    DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT,
                    DEFAULT)), CHAR(13), '') AS PlainText -- noqa: LT02
            FROM CTE
        )
        INSERT INTO upload.OutPutFile
        (
            Output
        )
        SELECT PlainText
        FROM CTEFinal AS SUB;


        DECLARE
            @CNT INT =
            (
                SELECT COUNT(*) FROM CellDayTemp.Upload.tblOutPutFile
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
END
-- noqa: disable=all
/
