--liquibase formatted sql

--changeset Nicolas Griesdorn e86a9636-780d-461c-bcc7-1c44f79b6021 stripComments:false runOnChange:true

USE [CellDay_Prod]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
/* =============================================
				:
	Author		: Nic Griesdorn
				:
	Created		: 2024-02-06
				:
	Description	: SP used in CRM to view and update Carrier IDs on IMEIs/ICCIDs
				:
	Test Data   : (2,259617,1,'356074104342550,89148000006962297238,015865000895499,89148000008091564397',29)
    NG20240307  : Added Sarah Haver to user list that can use this report
============================================= */
CREATE OR ALTER PROCEDURE [Report].[P_Report_Update_Carrier_ID]
    (
        @SessionID INT
        , @UserID INT
        , @Option INT
        , @IMEI_ICCID NVARCHAR(MAX)
        , @Carrier INT
    )
AS
BEGIN
    BEGIN TRY
        IF ISNULL(@SessionID, 0) <> 2
            RAISERROR (
                -- noqa: disable=all
                'This report is highly restricted. Please see your T-Cetra representative if you wish to request access.',
                -- noqa: enable=all
                12,
                1
            );

        IF ISNULL(@UserID, 0) = 0
            RAISERROR (
                -- noqa: disable=all
                'This report is highly restricted. Please see your T-Cetra representative if you wish to request access.',
                -- noqa: enable=all
                12,
                1
            );

        IF @UserID NOT IN (279685, 259617, 257210, 280015) -- Matt Moore, Nic Griesdorn, Tyler Fee, Sarah Haver NG20240307
            RAISERROR (
                -- noqa: disable=all
                'This user is not authorized to user this report, please contact T-CETRA Product Development Team if you need to change the carrier ID of a device.',
                -- noqa: enable=all
                14,
                1
            );

        IF OBJECT_ID('tempdb..#ListOfIMEIICCID') IS NOT NULL
            BEGIN
                DROP TABLE #ListOfIMEIICCID;
            END;

        CREATE TABLE #ListOfIMEIICCID (IMEI_ICCID VARCHAR(20))
        INSERT INTO #ListOfIMEIICCID (IMEI_ICCID)
        SELECT RESULT
        FROM [dbo].[FnGetStringInTable](@IMEI_ICCID, ',')


        --View
        IF @Option = 0
            BEGIN
                SELECT
                    pak.Sim_ID AS [IMEI/ICCID]
                    , pak.Active_Status AS [Active Status]
                    , pak.Status AS [Phone Active Kit Table Status]
                    , pak.Assigned_Merchant_ID AS [Current Assigned Account ID]
                    , a.Account_Name AS [Current Assigned Account Name]
                    , ci.Carrier_Name AS [Current Carrier]
                FROM #ListOfIMEIICCID AS loii
                JOIN dbo.Phone_Active_Kit AS pak ON pak.Sim_ID = loii.IMEI_ICCID
                JOIN dbo.Carrier_ID AS ci ON ci.ID = pak.Carrier_ID
                JOIN dbo.Account AS a ON a.Account_ID = pak.Assigned_Merchant_ID
                WHERE pak.Status = 1

            END;

        --Update Carrier ID
        IF @Option = 1
            BEGIN

                IF
                    EXISTS (
                        SELECT loii.*
                        FROM #ListOfIMEIICCID AS loii
                        LEFT JOIN dbo.Phone_Active_Kit AS p ON p.Sim_ID = loii.IMEI_ICCID
                        WHERE p.ID IS NULL
                    )
                    RAISERROR (
                        -- noqa: disable=all
                        'One or more of the IMEI or ICCID devices entered currently do not exist in the Phone Active Kit table, please make sure all devices first exist then try again.',
                        -- noqa: enable=all
                        14,
                        1
                    );

                IF
                    EXISTS (
                        SELECT loii.*
                        FROM #ListOfIMEIICCID AS loii
                        JOIN dbo.Phone_Active_Kit AS p ON p.Sim_ID = loii.IMEI_ICCID
                        WHERE p.Active_Status = 1
                    )
                    RAISERROR (
                        -- noqa: disable=all
                        'One or more of the IMEI or ICCID devices entered have already been activated. Please use the view option to see which device is activated and remove it and try again.',
                        -- noqa: enable=all
                        14,
                        1
                    );

                IF
                    NOT EXISTS (
                        SELECT loii.*
                        FROM #ListOfIMEIICCID AS loii
                        JOIN dbo.Phone_Active_Kit AS p ON p.Sim_ID = loii.IMEI_ICCID
                        WHERE P.Sim_ID = loii.IMEI_ICCID AND p.Status <> 0
                    )
                    RAISERROR (
                        -- noqa: disable=all
                        'There are currently no IMEI or ICCID(s) that are marked as active in the system, please check the IMEI or ICCID entered and try again. If this error persists please contact IT Support.',
                        -- noqa: enable=all
                        14,
                        1
                    );

                IF
                    EXISTS (
                        SELECT p.*
                        FROM dbo.Phone_Active_Kit AS p
                        JOIN #ListOfIMEIICCID AS loii ON p.Sim_ID = loii.IMEI_ICCID
                        WHERE p.Carrier_ID = @Carrier
                    )
                    RAISERROR (
                        -- noqa: disable=all
                        'The Carrier you are trying to update the record to already matches the one that is there, please select a different Carrier and try again.',
                        -- noqa: enable=all
                        14,
                        1
                    );

                MERGE dbo.Phone_Active_Kit AS p
                USING #ListOfIMEIICCID AS loii
                    ON
                        p.Sim_ID = loii.IMEI_ICCID
                        AND p.Status = 1
                WHEN MATCHED
                -- noqa: disable=all
                    THEN UPDATE SET p.Carrier_ID = @Carrier, p.Date_Updated = GETDATE(), p.User_Updated = 'ChangeCarrierIDCRM';
                -- noqa: enable=all

                SELECT
                    pak.Sim_ID AS [IMEI/ICCID]
                    , pak.Active_Status AS [Active Status]
                    , pak.Status AS [Phone Active Kit Table Status]
                    , pak.Assigned_Merchant_ID AS [Current Assigned Account ID]
                    , a.Account_Name AS [Current Assigned Account Name]
                    , ci.Carrier_Name AS [Current Carrier]
                FROM #ListOfIMEIICCID AS loii
                JOIN dbo.Phone_Active_Kit AS pak ON pak.Sim_ID = loii.IMEI_ICCID
                JOIN dbo.Carrier_ID AS ci ON ci.ID = pak.Carrier_ID
                JOIN dbo.Account AS a ON a.Account_ID = pak.Assigned_Merchant_ID
                WHERE pak.Status = 1

            END;

    END TRY
    BEGIN CATCH
        SELECT ERROR_MESSAGE() AS ErrorMessage;
    END CATCH;
END;
